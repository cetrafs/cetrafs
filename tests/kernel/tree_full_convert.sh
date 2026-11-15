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
# limit is reached in about a thousand writes. Seeded random 4 KiB
# O_DIRECT writes into a fallocated range until the first ENOSPC, then
# 200 more attempts:
#   setup: the limit was reached;
#   1. the file's allocated blocks did not shrink across the failures;
#   2. no preallocated block was given back (giveback_blocks);
#   3. after a remount every written block reads back, every other reads zeros;
#   4. fsck clean, and no block leaked.
#
# DISCRIMINATION: tree_append_room_off=1, on its own image: 1, 2 or 4 fail.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_root_cap tree_idx_cap tree_append_room_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt tfc)"
ct_track mnt "$MNT"
ct_param_set tree_append_room_off 0
NBLK=16384 # 64 MiB

# <file>: drive to the limit; prints "enospc=<0|1> b0=<st_blocks at the
# first ENOSPC> b1=<after 200 more attempts> fails=<ENOSPC count>"
drive() {
    python3 - "$1" "$NBLK" <<'PY'
import os, sys, ctypes, random, errno
path, nblk = sys.argv[1], int(sys.argv[2])
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if l.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
r = random.Random(7)
written, enospc, b0, fails = set(), 0, 0, 0
for _ in range(40000):
    b = r.randrange(nblk)
    if b in written:
        continue
    tag = b"blk%08d\n" % b
    mv[:] = (tag * (4096 // len(tag) + 1))[:4096]
    try:
        os.pwrite(fd, mv, b * 4096)
        written.add(b)
    except OSError as e:
        if e.errno != errno.ENOSPC:
            raise
        if not enospc:
            enospc, b0 = 1, os.fstat(fd).st_blocks
        fails += 1
        if fails >= 200:
            break
os.fsync(fd)
b1 = os.fstat(fd).st_blocks
os.close(fd)
with open(path + ".blocks", "w") as fh:
    fh.write(" ".join(map(str, sorted(written))))
print("enospc=%d b0=%d b1=%d fails=%d" % (enospc, b0, b1, fails))
PY
}

verify() { # <file> -> bad=<n>
    python3 - "$1" "$NBLK" <<'PY'
import sys
path, nblk = sys.argv[1], int(sys.argv[2])
written = set(int(x) for x in open(path + ".blocks").read().split())
bad = 0
with open(path, "rb") as fh:
    for b in range(nblk):
        d = fh.read(4096)
        tag = b"blk%08d\n" % b
        want = (tag * (4096 // len(tag) + 1))[:4096] if b in written else bytes(4096)
        bad += d != want
print("bad=%d" % bad)
PY
}

get() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

# <room_off 0|1> -> "<drive output> gb=<giveback delta> <verify> fsck=<clean|ERR|LEAK>"
round() {
    local dev proc g0 g1 d v out
    dev="$(ct_loop "$(ct_image 1200 "tfc$1")")"
    ct_mkfs "$dev" -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    ct_param_set tree_root_cap 1
    ct_param_set tree_idx_cap 8
    echo "$1" >/sys/module/cetrafs/parameters/tree_append_room_off
    g0="$(sed -n 's/^giveback_blocks: //p' "$proc/info")"
    d="$(drive "$MNT/f")"
    g1="$(sed -n 's/^giveback_blocks: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/tree_append_room_off
    ct_umount "$MNT"
    ct_param_set tree_root_cap 0
    ct_param_set tree_idx_cap 0
    ct_mount "$dev" "$MNT"
    v="$(verify "$MNT/f")"
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
    echo "$d gb=$((g1 - g0)) $v fsck=$out"
}

R="$(round 0)"
log "checked: $R"
C="$(round 1)"
log "control (no room check): $C"
[ "$(get enospc "$R")" = 1 ] && [ "$(get enospc "$C")" = 1 ] ||
    { fail "setup: a file never reached the tree's limit ($R | $C)"; ct_exit; }
pass "setup: both files reached the tree's limit ($(get fails "$R") refused writes)"
[ "$(get b1 "$R")" -ge "$(get b0 "$R")" ] && pass "1: allocated blocks kept across the failures ($(get b0 "$R") -> $(get b1 "$R"))" ||
    fail "1: allocated blocks fell from $(get b0 "$R") to $(get b1 "$R") across the failures"
[ "$(get gb "$R")" = 0 ] && pass "2: no preallocated block given back" ||
    fail "2: $(get gb "$R") preallocated block(s) given back"
[ "$(get bad "$R")" = 0 ] && pass "3: every block reads back right after a remount" || fail "3: $(get bad "$R") block(s) wrong"
[ "$(sed -n 's/.*fsck=//p' <<<"$R")" = clean ] && pass "4: fsck clean, nothing leaked" ||
    fail "4: fsck $(sed -n 's/.*fsck=//p' <<<"$R")"
if [ "$(get b1 "$C")" -lt "$(get b0 "$C")" ] || [ "$(get gb "$C")" != 0 ] ||
    [ "$(sed -n 's/.*fsck=//p' <<<"$C")" != clean ]; then
    pass "control: without the check the failing converts destroyed state"
else
    fail "control: without the check nothing was lost -- the suite cannot see the bug"
fi
ct_exit
