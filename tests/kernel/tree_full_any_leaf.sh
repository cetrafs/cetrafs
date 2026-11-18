#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a full tree fills free leaf slots before it returns ENOSPC
#
# A tree takes new leaves only through its last path, and the deepest
# tree has four top interiors at most; once the last path is full, the
# append returned ENOSPC.
# An append-only tree fills every leaf before it gets there. A range split
# (cetrafs_tree_split_leaf()) leaves both halves part full, so on its own
# it would reach ENOSPC holding fewer extents -- the "VM pauses on nospace
# with space free" path, sooner. At the limit the append now fills any
# leaf with a free slot (cetrafs_tree_insert_any_leaf()).
#
# The tree is capped for the suite (TEST ONLY tree_root_cap=1,
# tree_idx_cap=3: nine leaves at depth 3) so the limit is reached
# in about a thousand writes. Three files, the same seeded random 4 KiB
# O_DIRECT writes into a fallocated range until the first ENOSPC:
#   append    leaf_split_off=1     -- the reference
#   split     (defaults)           -- must hold at least as many extents
#   control   tree_any_leaf_off=1  -- split without the fallback: fewer
# Then every block written before the ENOSPC reads back after a remount,
# and fsck is clean.
#
# DISCRIMINATION: the control above.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_root_cap tree_idx_cap tree_any_leaf_off leaf_split_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 1200 treefull)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt treefull)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
ct_param_set leaf_split_off 0
ct_param_set tree_any_leaf_off 0
ct_param_set tree_root_cap 1
ct_param_set tree_idx_cap 3

NBLK=16384 # 64 MiB

# <file> <seed>: prints "writes=<ok writes> enospc=<0|1> extents=<n>",
# and the written block numbers to <file>.blocks.
drive() {
    python3 - "$1" "$2" "$NBLK" <<'PY'
import os, sys, ctypes, random, errno, fcntl, struct
path, seed, nblk = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
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
done, enospc, written = 0, 0, []
for _ in range(20000):
    b = r.randrange(nblk)
    tag = (b"blk%08d-seed%04d\n" % (b, seed))
    mv[:] = (tag * (4096 // len(tag) + 1))[:4096]
    try:
        os.pwrite(fd, mv, b * 4096)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            enospc = 1
            break
        raise
    done += 1
    written.append(b)
os.fsync(fd)
fm = fcntl.ioctl(fd, 0xC020660B, struct.pack("QQIIII", 0, 0xFFFFFFFFFFFFFFFF, 0, 0, 0, 0))
ext = struct.unpack("QQIIII", fm)[3]
os.close(fd)
with open(path + ".blocks", "w") as fh:
    fh.write(" ".join(map(str, written)))
print("writes=%d enospc=%d extents=%d" % (done, enospc, ext))
PY
}

get() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

ct_param_set leaf_split_off 1
A="$(drive "$MNT/append" 1)"
ct_param_set leaf_split_off 0
S="$(drive "$MNT/split" 1)"
ct_param_set tree_any_leaf_off 1
C="$(drive "$MNT/control" 1)"
ct_param_set tree_any_leaf_off 0
log "append: $A"
log "split: $S"
log "control: $C"
for v in "$A" "$S" "$C"; do
    [ "$(get enospc "$v")" = 1 ] || { fail "setup: a file never reached the tree's limit ($v)"; ct_exit; }
done
pass "setup: all three files reached the tree's limit"
EA="$(get extents "$A")"; ES="$(get extents "$S")"; EC="$(get extents "$C")"
[ "$ES" -ge "$EA" ] && pass "the split tree holds $ES extents at its limit, the append-only one $EA" ||
    fail "the split tree holds $ES extents at its limit, fewer than the append-only $EA"
[ "$EC" -lt "$EA" ] && pass "control: without the fallback the split tree holds only $EC" ||
    fail "control: without the fallback the split tree still holds $EC (append-only $EA) -- the suite cannot see the loss"

log "content after a remount, and fsck"
ct_umount "$MNT"
ct_param_set tree_root_cap 0
ct_param_set tree_idx_cap 0
ct_mount "$DEV" "$MNT"
for f in append split control; do
    out="$(python3 - "$MNT/$f" "$NBLK" <<'PY'
import sys
path, nblk = sys.argv[1], int(sys.argv[2])
written = set(int(x) for x in open(path + ".blocks").read().split())
bad = 0
with open(path, "rb") as fh:
    for b in range(nblk):
        d = fh.read(4096)
        if b in written:
            tag = (b"blk%08d-seed%04d\n" % (b, 1))
            ok = d == (tag * (4096 // len(tag) + 1))[:4096]
        else:
            ok = d == bytes(4096)
        if not ok:
            bad += 1
print("bad=%d" % bad)
PY
)"
    [ "$out" = bad=0 ] && pass "$f: every block reads back right" || fail "$f: $out"
done
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -m3 -E 'ERR' | tr '\n' ' ')"
ct_exit
