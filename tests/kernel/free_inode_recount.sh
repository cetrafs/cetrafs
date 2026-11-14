#!/usr/bin/env bash
# statfs reports a free-inode count that follows the bitmap, not only this node's own creates
#
# The free-inode count was seeded once, at mount, and adjusted by this
# node's creates and unlinks only. A peer's allocations never reached it,
# so df -i drifted without bound (audit O9). statfs now recounts the
# bitmap, fresh, when the value is older than ten seconds.
#
# Staged on one mount: the bitmap is changed on the device behind the
# mounted node's back -- one free inode taken, as a peer's create would
# take it -- with the node's own cached copy of that bitmap block left as
# it was. The statfs after the next recount must show one fewer free inode.
#
#  1. control: a statfs with nothing changed reports the count it had.
#  2. a peer takes an inode on the device; after the recount window a
#     statfs reports one fewer free inode.
#
# DISCRIMINATION: with the seed-only count (the pre-fix code) case 2 still
# reports the old count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBP="$(ct_helper sb_poke)"

IMG="$(ct_image 560 freeino)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt freeino)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

ffree() { stat -f -c %d "$MNT"; }
BMAP="$("$SBP" "$IMG" | sed -n 's/^inode_bmap_start[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$BMAP" ] || { fail "setup: sb_poke does not report inode_bmap_start"; ct_exit; }

F0="$(ffree)"
sleep 11 # the first statfs may recount; let the window pass so the next one does too
F1="$(ffree)"
[ "$F1" = "$F0" ] && pass "1: control: an unchanged bitmap reports the same free inodes ($F0)" ||
    fail "1: control: the free-inode count moved with nothing changed ($F0 -> $F1)"

# A peer's create: inode 900 taken on the device (bit 900 of the inode bitmap).
python3 -I - "$IMG" "$BMAP" <<'PY'
import os, sys
img, bmap = sys.argv[1], int(sys.argv[2])
ino = 900
off = bmap * 4096 + ino // 8
fd = os.open(img, os.O_RDWR)
b = os.pread(fd, 1, off)[0]
was = (b >> (ino % 8)) & 1
os.pwrite(fd, bytes([b | (1 << (ino % 8))]), off)
os.fsync(fd)
os.close(fd)
print("was %d" % was)
sys.stdout.flush()
PY
sleep 11
F2="$(ffree)"
[ "$F2" = "$((F0 - 1))" ] && pass "2: after the recount window the peer's inode is counted ($F0 -> $F2)" ||
    fail "2: the free-inode count does not follow the bitmap: $F0 before the peer's create, $F2 after"
ct_umount "$MNT"
ct_exit
