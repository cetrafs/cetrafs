#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a leaf split never hides a written extent from a lockless lookup
#
# A full leaf a convert meets is split by range (cetrafs_tree_split_leaf()):
# the new leaf goes into an interior first, then the moved entries leave
# the old one. A lookup that holds no invalidate_lock -- an O_DIRECT read,
# writeback -- walks an interior entry by entry, releasing it before each
# leaf. If the new leaf lands at a slot the walk has already passed, and
# the old leaf loses the entries before the walk reads it, the walk finds
# the block in neither: a WRITTEN block reads as zeros, and writeback of a
# dirty page over it has nowhere to go.
#
# A move is bracketed (cetrafs_tree_move_begin()): the walk samples the
# inode's move sequence first, and a miss under or across a move walks
# again (bounded; at the bound -EIO, never a silent miss).
#
#  1. A depth-2 fallocated file, block 0 written first, then random writes
#     away from blocks 1..63 so blocks 0 and 1 share a leaf.
#  2. After a remount (nothing cached), an async O_DIRECT write of block
#     1: its completion converts the block -- with no i_rwsem, which is
#     why it can run beside an O_DIRECT read -- forced to split
#     (leaf_split_force), the new leaf at slot 0 (leaf_split_place_first),
#     held before any entry moves (leaf_split_stall_ms). An O_DIRECT read
#     of block 0 starts meanwhile and is held before its first leaf read
#     (lookup_stall_*), long enough for the whole split to run: its walk
#     is past slot 0 and the old leaf has lost block 0. The read must
#     return block 0's data, and tree_move_reruns must move.
#  3. CONTROL, the same on a second file with tree_move_rerun_off=1: the
#     read returns zeros. Setup on both: the read was held the full stall
#     with the write still in flight, and the split ran.
#  4. Both files read back right after a remount; fsck is clean.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit (1064028) would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
for p in lookup_stall_ms tree_move_rerun_off leaf_split_force leaf_split_place_first leaf_split_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

AIO="$(ct_helper dio_aio)"

IMG="$(ct_image 600 splithide)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt splithide)"
ct_track mnt "$MNT"
PD="$(basename "$DEV")"
ct_mkfs "$DEV" -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set leaf_split_off 0
c() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }

NBLK=16384 # 64 MiB
NW=1500
WSTALL=1500 # the split, held before its entries move
STALL=3000  # the read, held before its first leaf: outlasts the split

# <file> <seed>: fallocate; block 0 first, then seeded random writes
# outside 1..63. Each written block holds its number and the seed.
fill() {
    python3 - "$1" "$2" "$NBLK" "$NW" <<'PY'
import os, sys, ctypes, random
path, seed, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if l.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
r = random.Random(seed)
blocks = [0] + [r.randrange(64, nblk) for _ in range(nw)]
for b in blocks:
    tag = (b"blk%08d-seed%04d\n" % (b, seed))
    mv[:] = (tag * (4096 // len(tag) + 1))[:4096]
    os.pwrite(fd, mv, b * 4096)
os.fsync(fd)
os.close(fd)
PY
}

# <file>: an async O_DIRECT write of block 1, whose completion converts
# it -- forced to split, the new leaf at slot 0, and held before any entry
# moves (leaf_split_stall_ms). Meanwhile an O_DIRECT read of block 0
# starts, samples the tree, and is held before its first leaf read
# (lookup_stall_ms) -- longer, so the whole split runs under it. Sets OUT
# (the helper's "inflight=<0|1> read=<n> first=<c>"; 'b' is block 0's
# data, '0' zeros), MS (the read's duration) and SPLITS.
race() {
    local f="$1" ino s0 t0 t1
    ino="$(stat -c %i "$f")"
    s0="$(c leaf_splits)"
    ct_param_set leaf_split_place_first 1
    ct_param_set leaf_split_force 1
    ct_param_set leaf_split_stall_ms "$WSTALL"
    ct_param_set lookup_stall_ino "$ino"
    ct_param_set lookup_stall_block 0
    ct_param_set lookup_stall_ms "$STALL"
    t0="$(date +%s%N)"
    OUT="$("$AIO" readmid "$f" 4096 4096 300 0)"
    t1="$(date +%s%N)"
    MS=$(((t1 - t0) / 1000000))
    SPLITS=$(($(c leaf_splits) - s0))
    ct_param_set leaf_split_force 0
    ct_param_set leaf_split_place_first 0
    ct_param_set leaf_split_stall_ms 0
    ct_param_set lookup_stall_ms 0
}
arranged() { # <part>
    [ "$MS" -ge "$STALL" ] && [ "$SPLITS" -ge 1 ] && grep -q 'inflight=1' <<<"$OUT" &&
        pass "$1: setup: the read was held ${MS}ms with the write in flight, and $SPLITS split(s) ran" ||
        fail "$1: setup: held ${MS}ms, $SPLITS split(s), $OUT -- the race was not arranged"
}

log "1: two depth-2 fallocated files"
fill "$MNT/fix" 1 || { skip "fallocate unsupported here"; ct_umount "$MNT"; ct_exit; }
fill "$MNT/ctl" 2
pass "1: written (depth 2 is proved below: the stall and the split are both depth-2 only)"

log "2: the stalled read of block 0 across a split"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
R0="$(c tree_move_reruns)"
race "$MNT/fix"
R1="$(c tree_move_reruns)"
arranged 2
grep -q 'read=4096 first=b' <<<"$OUT" && pass "2: the read returned block 0's data" ||
    fail "2: the read of block 0 returned: $OUT"
[ "$((R1 - R0))" -ge 1 ] && pass "2: the walk re-ran across the move ($((R1 - R0)))" ||
    fail "2: tree_move_reruns did not move -- the read found the block without the re-run, so the suite does not reach the window"

log "3: control -- the same race with the re-run off"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
ct_param_set tree_move_rerun_off 1
race "$MNT/ctl"
ct_param_set tree_move_rerun_off 0
arranged 3
grep -q 'read=4096 first=0' <<<"$OUT" && pass "3: control: without the re-run the written block read as zeros" ||
    fail "3: control: without the re-run the read returned: $OUT -- the suite cannot tell the fix from its absence"

log "4: content after a remount, and fsck"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
for f in fix:1 ctl:2; do
    out="$(python3 - "$MNT/${f%%:*}" "${f##*:}" "$NBLK" "$NW" <<'PY'
import sys, random
path, seed, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r = random.Random(seed)
written = set([0] + [r.randrange(64, nblk) for _ in range(nw)])
bad = 0
zero = bytes(4096)
with open(path, "rb") as fh:
    for b in range(nblk):
        d = fh.read(4096)
        if b == 1:
            ok = d == b"D" * 4096
        elif b in written:
            tag = (b"blk%08d-seed%04d\n" % (b, seed))
            ok = d == (tag * (4096 // len(tag) + 1))[:4096]
        else:
            ok = d == zero
        if not ok:
            bad += 1
            if bad <= 3:
                print("block %d wrong" % b)
print("bad=%d" % bad)
PY
)"
    grep -q "^bad=0$" <<<"$out" && pass "4: ${f%%:*}: every block reads back right after a remount" ||
        fail "4: ${f%%:*}: $(tr '\n' ' ' <<<"$out")"
done
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "4: fsck clean" || fail "4: fsck: $(ct_fsck "$DEV" 2>&1 | grep -m3 ERR | tr '\n' ' ')"
ct_exit
