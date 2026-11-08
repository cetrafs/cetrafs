#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a ranged fsync converts the pending set without writing back the whole file
#
# A buffered write into preallocated space is marked written only at a
# boundary, after its data is down (cetrafs_convert_pending_locked()).
# That writeback covered the WHOLE file, so an O_DSYNC write of one block
# of a large image with dirty pages elsewhere wrote them all back before
# returning. Only the pending set's span needs its data down first; every
# caller writes back its own range itself.
#
#   setup: a 4 MiB file written and fsynced; periodic writeback off;
#     blocks 0..63 overwritten (dirty, not pending -- already written).
#   the act: one O_DSYNC write into preallocated space at block 300.
#   the check: block 300 is on the device; blocks 0..63 are not (still
#     the old pattern there); after unmount and remount every block reads
#     its newest pattern.
#
# DISCRIMINATION: with the whole-file writeback, blocks 0..63 reach the
# device during the O_DSYNC write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 pspan)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pspan)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
F="$MNT/img"
python3 - "$F" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(8 << 20)) == 0
for b in range(256):
    os.pwrite(fd, (b"A%07d" % b) * 512, b * 4096)
os.fsync(fd)
os.close(fd)
PY
FI="$(stat -c %i "$F")"
phys() { filefrag -v -b4096 "$F" | awk -v l="$1" -F'[: .]+' '$2 ~ /^[0-9]+$/ && l >= $3 && l <= $4 { print $5 + (l - $3); exit }'; }
dev_blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | head -c 8; }
P10="$(phys 10)"
[ -n "$P10" ] && [ "$(dev_blk "$P10")" = A0000010 ] || { fail "setup: block 10 is not on the device ('$P10')"; ct_exit; }

EXP0="$(cat /proc/sys/vm/dirty_expire_centisecs)"
WB0="$(cat /proc/sys/vm/dirty_writeback_centisecs)"
ct_track cmd "echo $EXP0 >/proc/sys/vm/dirty_expire_centisecs; echo $WB0 >/proc/sys/vm/dirty_writeback_centisecs"
echo 360000 >/proc/sys/vm/dirty_expire_centisecs
echo 0 >/proc/sys/vm/dirty_writeback_centisecs
P300="$(phys 300)"
[ -n "$P300" ] || { fail "setup: block 300 is not preallocated"; ct_exit; }
# Checked with both fds still OPEN: a close(2) is a boundary of its own
# (->flush writes the whole file back, as it should).
RES="$(python3 - "$F" "$IMG" "$P10" "$P300" <<'PY'
import os, sys
f, img, p10, p300 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
fd = os.open(f, os.O_RDWR)
for b in range(64):
    os.pwrite(fd, (b"B%07d" % b) * 512, b * 4096)
fd2 = os.open(f, os.O_RDWR | os.O_DSYNC)
os.pwrite(fd2, b"DSYNC300" * 512, 300 * 4096)
dev = os.open(img, os.O_RDONLY)
print(os.pread(dev, 8, p300 * 4096).decode(errors="replace"), os.pread(dev, 8, p10 * 4096).decode(errors="replace"))
os.close(dev)
os.close(fd2)
os.close(fd)
PY
)"
read -r D300 D10 <<<"$RES"
[ "$D300" = DSYNC300 ] && pass "the O_DSYNC write is on the device" ||
    fail "the O_DSYNC write is not on the device (reads '$D300')"
[ "$D10" = A0000010 ] && pass "the unrelated dirty pages were not written back by it" ||
    fail "the O_DSYNC write wrote back the whole file (block 10 reads '$D10' on the device)"
echo "$EXP0" >/proc/sys/vm/dirty_expire_centisecs
echo "$WB0" >/proc/sys/vm/dirty_writeback_centisecs

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
BAD="$(python3 - "$F" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = []
for b in range(256):
    want = (b"B%07d" % b) if b < 64 else (b"A%07d" % b)
    if os.pread(fd, 8, b * 4096) != want:
        bad.append(str(b))
if os.pread(fd, 8, 300 * 4096) != b"DSYNC300":
    bad.append("300")
print(" ".join(bad[:8]))
PY
)"
[ -z "$BAD" ] && pass "after a remount every block reads its newest data" || fail "blocks wrong after remount: $BAD"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" || fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
