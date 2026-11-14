#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refused cache flush keeps the buffered blocks pending instead of dropping them
#
# Buffered blocks are marked written at a boundary, after their data is
# written back and the device cache flushed. A refused flush used to
# drop the whole pending set, exactly as a failed writeback does -- but
# after a flush failure the writes HAVE completed, only their durability
# is unknown: dropping made every block of the set unwritten for good,
# reading zeros, while its data sat on the device. One multipath flap
# failing a SYNCHRONIZE CACHE was enough (audit 2026-11-14 FD-2).
#
#   1. fsync with the flush refused (pending_flush_fail) fails; with the
#      flush back, the next fsync converts, and after a remount the file
#      reads back what was written;
#   2. a last close whose flush keeps failing stops the mount instead of
#      dropping the set.
#
# DISCRIMINATION: proven 2026-11-14 by reverting the fix -- 1 reads the
# blocks back as zeros, 2 leaves the mount running.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pending_flush_fail ] || { skip "pending_flush_fail is missing"; ct_exit; }
MNT="$(ct_mnt pfe)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set pending_flush_fail 0
KNOB=/sys/module/cetrafs/parameters/pending_flush_fail

# <file> <fail_first_fsync 0|1>: write 1 MiB of a pattern into a
# preallocated file, fsync (refused when asked), fsync again, close.
# Prints "<first fsync> <second fsync>".
writer() {
    python3 - "$1" "$2" "$KNOB" <<'PY'
import os, sys
path, fail, knob = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
fd = os.open(path, os.O_RDWR)
os.pwrite(fd, b"P" * (1 << 20), 0)
def sync():
    try:
        os.fsync(fd)
        return "ok"
    except OSError as e:
        return e.strerror.replace(" ", "_")
if fail:
    open(knob, "w").write("1")
a = sync()
open(knob, "w").write("0")
b = sync()
os.close(fd)
print(a, b, flush=True)
PY
}

DEV="$(ct_loop "$(ct_image 560 pfe1)")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
fallocate -l 4M "$MNT/f"
read -r A B <<<"$(writer "$MNT/f" 1)"
[ "$A" != ok ] && pass "1: fsync with the cache flush refused fails ($A)" ||
    fail "setup 1: fsync succeeded with the cache flush refused"
[ "$B" = ok ] || fail "1: the second fsync, the flush back, failed: $B"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
GOT="$(head -c 1048576 "$MNT/f" | tr -d P | wc -c)"
[ "$GOT" = 0 ] && pass "1: after a remount the file reads back what was written" ||
    fail "1: after a remount $GOT of 1048576 bytes do not read back -- the refused flush dropped the pending set"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$out" && fail "1: fsck: $(grep '^ERR' <<<"$out" | head -2)" || pass "1: fsck clean"

DEV="$(ct_loop "$(ct_image 560 pfe2)")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
fallocate -l 4M "$MNT/g"
python3 - "$MNT/g" "$KNOB" <<'PY' || true
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b"Q" * (1 << 20), 0)
open(sys.argv[2], "w").write("1")
try:
    os.close(fd)
except OSError:
    pass
PY
echo 0 >"$KNOB"
STOP="$(sed -n 's/^fenced: //p' "$(ct_procdir "$DEV")/info")"
[ "$STOP" = yes ] && pass "2: a last close whose flush kept failing stopped the mount rather than drop the set" ||
    fail "2: the last close dropped the pending set and the mount runs on (fenced: $STOP)"
umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
ct_exit
