#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an edit made between a boundary's target write and its settle is not lost
#
# sync(2) writes the held-back tree blocks of an inode that is not in
# core with no lock against that file (cetrafs_deferred_flush_all()):
# there is no inode to take one on, and the file can be opened and
# written meanwhile. An update finding a block's held-back bit set trusts
# it as "listed already"; the batch used to unlist the block after its
# write without looking, so an edit landing between the two was neither
# dirty nor listed and never reached the device (leafdefer review 2026-11-08, item
# 1). Now the bit and the listing go together under the buffer lock, and
# a block whose image changed since it was written stays listed, against
# the image now on the device.
#
# deferred_flush_no_inode makes sync take that path for a file this node
# has open -- the lockless batch is the condition, not how the inode got
# out of core -- and deferred_settle_stall_ms holds it between the target
# writes and the settle.
#   setup: a preallocated file with an external leaf, held open for
#     writing (so no close is a boundary); an O_DIRECT write edits the
#     leaf, held back. sync starts and pauses after writing it.
#   the race: inside the pause, a second O_DIRECT write edits the same
#     leaf (its completion converts the block at once).
#   the check: sync again, unmount, remount -- both blocks read back.
#
# DISCRIMINATION: with the settle unlisting unconditionally (the old
# clear), the second edit is never written and its block reads zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in deferred_settle_stall_ms deferred_flush_no_inode; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LP="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 dsr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dsr)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
F="$MNT/img"

# dio_write <path> <block> <tag> [fsync]: one 4 KiB O_DIRECT write of
# <tag> repeated.
dio_write() {
    python3 - "$@" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(sys.argv[3].encode() * (4096 // len(sys.argv[3])))
os.pwritev(fd, [buf], int(sys.argv[2]) * 4096)
if len(sys.argv) > 4:
    os.fsync(fd)
os.close(fd)
PY
}
python3 - "$F" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(4 << 20)) == 0
os.close(fd)
PY
for i in $(seq 0 23); do dio_write "$F" $((i * 4)) "$(printf 'B%07d' $((i * 4)))"; done
dio_write "$F" 96 B0000096 fsync
INO="$(stat -c %i "$F")"
L="$("$LP" "$IMG" leaf "$INO" 2>/dev/null || true)"
[ -n "$L" ] && [ "$L" -gt 0 ] 2>/dev/null || { fail "setup: no external leaf"; ct_exit; }

exec 7<>"$F" # held open for writing: no close below is a boundary
dio_write "$F" 120 FIRST001
ct_param_set deferred_flush_no_inode 1
ct_param_set deferred_settle_stall_ms 3000
MARK="$(dmesg_mark)"
sync &
SP=$!
for _ in $(seq 1 50); do
    dmesg_since "$MARK" | grep -q 'TEST pause of [0-9]*ms between the target writes and the settle (inode not in core)' && break
    sleep 0.1
done
if ! dmesg_since "$MARK" | grep -q 'TEST pause'; then
    wait $SP || true
    ct_param_set deferred_settle_stall_ms 0
    ct_param_set deferred_flush_no_inode 0
    exec 7>&-
    fail "setup: sync never reached the settle pause on the lockless path"
    ct_exit
fi
pass "setup: sync is between the target writes and the settle, with no lock against the file"
dio_write "$F" 200 RACE0001 # the race: an edit of the same leaf, inside the pause
wait $SP || true
ct_param_set deferred_settle_stall_ms 0
sync
ct_param_set deferred_flush_no_inode 0
exec 7>&-

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
blk() { dd if="$F" bs=4096 skip="$1" count=1 status=none | head -c 8; }
[ "$(blk 120)" = FIRST001 ] && pass "setup: the edit the paused sync wrote reached the device" ||
    fail "setup: the edit written by the paused sync is missing (block 120 reads '$(blk 120)')"
[ "$(blk 200)" = RACE0001 ] && pass "the edit made inside the pause reached the device" ||
    fail "the edit made between the target write and the settle was lost (block 200 reads '$(blk 200)')"
BAD=""
for i in $(seq 0 24); do [ "$(blk $((i * 4)))" = "$(printf 'B%07d' $((i * 4)))" ] || BAD="$BAD $((i * 4))"; done
[ -z "$BAD" ] && pass "every block written before reads back" || fail "blocks lost:$BAD"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
