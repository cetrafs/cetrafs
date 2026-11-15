#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write into preallocated space at the tree's limit fails with nothing changed
#
# A write into a preallocated (uninit) extent whose leaf is full shrinks
# that extent in place and appends the written block, and the rest of
# the preallocation, through the tree (CETRAFS_CONVERT_APPEND). At the
# tree's limit that append has nowhere to go. It used to fail only AFTER
# the shrink was held back: the written block dropped out of the map --
# allocated, referenced by nothing -- and the preallocated tail was given
# back, for a write that failed ENOSPC anyway (audit 2026-11-14 A-1).
# Now the convert checks the append's room first
# (cetrafs_tree_append_room()) and refuses with nothing modified.
#
# The tree is capped (TEST ONLY tree_root_cap=1, tree_idx_cap=8) so the
# limit is reached in about a thousand writes. Seeded random 4 KiB writes
# into a preallocated range until the first ENOSPC, then 200 more
# attempts, in the three shapes the second audit round rated CRITICAL
# (B-2):
#   dio     O_DIRECT into a fallocated range;
#   zero    O_DIRECT into a range FALLOC_FL_ZERO_RANGE made over a hole
#           (a thin image after a guest's write-zeroes);
#   buf     buffered writes, each fsynced, into a fallocated range: the
#           convert runs at writeback and its ENOSPC reaches the fsync.
# For each:
#   setup: the limit was reached;
#   1. the file's allocated blocks did not shrink across the failures;
#   2. no preallocated block was given back (giveback_blocks);
#   3. after a remount every written block reads back, every other reads zeros;
#   4. fsck clean, and no block leaked;
#   5. the mount kept running -- for buf, the last close finds blocks it
#      could not convert for room, which stopped the mount (B-8).
#
# DISCRIMINATION: tree_append_room_off=1, on its own image, per shape:
# 1, 2 or 4 fail. close_nospc_stops=1 (buf): the mount stops.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_root_cap tree_idx_cap tree_append_room_off close_nospc_stops; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt tfc)"
ct_track mnt "$MNT"
ct_param_set tree_append_room_off 0
ct_param_set close_nospc_stops 0
NBLK=16384 # 64 MiB

# <file>: drive to the limit; prints "enospc=<0|1> b0=<st_blocks at the
# first ENOSPC> b1=<after 200 more attempts> fails=<ENOSPC count>"
drive() {
    python3 - "$1" "$NBLK" "$2" <<'PY'
import os, sys, ctypes, random, errno
path, nblk, shape = sys.argv[1], int(sys.argv[2]), sys.argv[3]
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if shape == "zero":
    os.ftruncate(fd, nblk * 4096)  # a hole, then write-zeroes over it
    mode = 0x10  # FALLOC_FL_ZERO_RANGE
else:
    mode = 0
if l.fallocate(fd, mode, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(path, os.O_RDWR | (0 if shape == "buf" else os.O_DIRECT))
r = random.Random(7)
written, failed, enospc, b0, fails = set(), set(), 0, 0, 0
for _ in range(40000):
    b = r.randrange(nblk)
    if b in written:
        continue
    tag = b"blk%08d\n" % b
    mv[:] = (tag * (4096 // len(tag) + 1))[:4096]
    try:
        os.pwrite(fd, mv, b * 4096)
        if shape == "buf":
            os.fsync(fd)
        written.add(b)
    except OSError as e:
        if e.errno != errno.ENOSPC:
            raise
        failed.add(b)
        if not enospc:
            enospc, b0 = 1, os.fstat(fd).st_blocks
        fails += 1
        if fails >= 200:
            break
try:
    os.fsync(fd)
except OSError:
    pass
b1 = os.fstat(fd).st_blocks
try:
    os.close(fd)  # buf: the last close converts too, and says ENOSPC
except OSError as e:
    if e.errno != errno.ENOSPC:
        raise
with open(path + ".blocks", "w") as fh:
    fh.write(" ".join(map(str, sorted(written))))
# a refused buffered write may still be converted by a later fsync that
# found room: either content is right for it, never anything else
with open(path + ".failed", "w") as fh:
    fh.write(" ".join(map(str, sorted(failed - written))))
print("enospc=%d b0=%d b1=%d fails=%d" % (enospc, b0, b1, fails))
PY
}

verify() { # <file> -> bad=<n>
    python3 - "$1" "$NBLK" <<'PY'
import sys
path, nblk = sys.argv[1], int(sys.argv[2])
written = set(int(x) for x in open(path + ".blocks").read().split())
failed = set(int(x) for x in open(path + ".failed").read().split())
bad = 0
with open(path, "rb") as fh:
    for b in range(nblk):
        d = fh.read(4096)
        tag = b"blk%08d\n" % b
        data = (tag * (4096 // len(tag) + 1))[:4096]
        if b in failed:
            bad += d not in (data, bytes(4096))
        else:
            bad += d != (data if b in written else bytes(4096))
print("bad=%d" % bad)
PY
}

get() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

# <room_off 0|1|stop> <shape>; "stop": the room check on, and the B-8
# control close_nospc_stops=1 -> "<drive output> gb=<giveback delta> stopped=<yes|no> <verify> fsck=<clean|ERR|LEAK>"
round() {
    local dev proc g0 g1 d v out st
    dev="$(ct_loop "$(ct_image 1200 "tfc$1$2")")"
    ct_mkfs "$dev" -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    ct_param_set tree_root_cap 1
    ct_param_set tree_idx_cap 8
    if [ "$1" = stop ]; then
        echo 1 >/sys/module/cetrafs/parameters/close_nospc_stops
    else
        echo "$1" >/sys/module/cetrafs/parameters/tree_append_room_off
    fi
    g0="$(sed -n 's/^giveback_blocks: //p' "$proc/info")"
    d="$(drive "$MNT/f" "$2")"
    g1="$(sed -n 's/^giveback_blocks: //p' "$proc/info" 2>/dev/null || echo "$g0")"
    st="$(sed -n 's/^shutdown: //p' "$proc/controls" 2>/dev/null || echo yes)"
    echo 0 >/sys/module/cetrafs/parameters/tree_append_room_off
    echo 0 >/sys/module/cetrafs/parameters/close_nospc_stops
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    ct_param_set tree_root_cap 0
    ct_param_set tree_idx_cap 0
    ct_mount "$dev" "$MNT"
    v="$(verify "$MNT/f" 2>/dev/null || echo bad=unread)"
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    if grep -qE '^ERR' <<<"$out"; then
        log "fsck ($1): $(grep -m2 -E '^ERR' <<<"$out" | tr '\n' ' ')" >&2
        out=ERR
    elif grep -q 'leaked' <<<"$out"; then
        log "fsck ($1): $(grep -m1 'leaked' <<<"$out")" >&2
        out=LEAK
    else
        out=clean
    fi
    echo "$d gb=$((g1 - g0)) stopped=$st $v fsck=$out"
}

for SH in dio zero buf; do
    R="$(round 0 "$SH")"
    log "$SH checked: $R"
    C="$(round 1 "$SH")"
    log "$SH control (no room check): $C"
    [ "$(get enospc "$R")" = 1 ] ||
        { fail "$SH setup: a file never reached the tree's limit ($R)"; continue; }
    pass "$SH setup: both files reached the tree's limit ($(get fails "$R") refused writes)"
    [ "$(get b1 "$R")" -ge "$(get b0 "$R")" ] && pass "$SH 1: allocated blocks kept across the failures ($(get b0 "$R") -> $(get b1 "$R"))" ||
        fail "$SH 1: allocated blocks fell from $(get b0 "$R") to $(get b1 "$R") across the failures"
    [ "$(get gb "$R")" = 0 ] && pass "$SH 2: no preallocated block given back" ||
        fail "$SH 2: $(get gb "$R") preallocated block(s) given back"
    [ "$(get bad "$R")" = 0 ] && pass "$SH 3: every block reads back right after a remount" || fail "$SH 3: $(get bad "$R") block(s) wrong"
    [ "$(sed -n 's/.*fsck=//p' <<<"$R")" = clean ] && pass "$SH 4: fsck clean, nothing leaked" ||
        fail "$SH 4: fsck $(sed -n 's/.*fsck=//p' <<<"$R")"
    [ "$(sed -n 's/.*stopped=\([a-z]*\).*/\1/p' <<<"$R")" = no ] && pass "$SH 5: the mount kept running" ||
        fail "$SH 5: the mount stopped"
    # a control whose writer died of EIO printed nothing: that too is
    # the destroyed state (B-2: in-flight writes into the given-back tail)
    if [ -z "$(get enospc "$C")" ] || [ "$(get b1 "$C")" -lt "$(get b0 "$C")" ] || [ "$(get gb "$C")" != 0 ] ||
        [ "$(sed -n 's/.*fsck=//p' <<<"$C")" != clean ]; then
        pass "$SH control: without the check the failing converts destroyed state"
    else
        fail "$SH control: without the check nothing was lost -- the suite cannot see the bug"
    fi
done
# B-8: the buffered shape's last close finds blocks it could not convert
# for room. That stopped the mount; with the old verdict it still does.
S="$(round stop buf)"
log "buf, close_nospc_stops=1: $S"
[ "$(sed -n 's/.*stopped=\([a-z]*\).*/\1/p' <<<"$S")" = yes ] &&
    pass "buf control: the old verdict stops the mount at the last close" ||
    fail "buf control: the old verdict did not stop the mount -- the suite does not reach the close"
ct_exit
