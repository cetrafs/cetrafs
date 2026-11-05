#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a metadata sync that finds writeback's write already failed reports it
#
# cetrafs_sync_buffer() writes a dirty buffer and says whether it landed.
# A buffer it found CLEAN -- because a write already in flight took the
# dirt, which is what the flusher does -- returned 0 without looking at
# BH_Write_EIO. Writeback has no caller to look at its result, so when
# that write failed the record/dirent/leaf update it carried was lost in
# silence: no error to the operation, no stop of the mount (audit
# 2026-11-05, class 16). __cetrafs_sync_buffer_keep() already checked it.
#
# sync_writeback_eio leaves the next synchronous metadata write's buffer
# the way a failed flusher write does: clean, BH_Write_EIO set. The real
# interleaving -- the flusher taking the buffer between an update and its
# sync -- cannot be scheduled from a test; this stages its end state on
# the real path. A create must then fail and the mount stop (kind 3, the
# same as a refused synchronous write).
#
# DISCRIMINATION: proven 2026-11-05 with the old clean-path return (knob
# kept): the create succeeds and the mount runs on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
compress_timing
[ -w /sys/module/cetrafs/parameters/sync_writeback_eio ] || { skip "sync_writeback_eio is missing"; ct_exit; }

DEV="$(ct_dev 560 sbwe)"
MNT="$(ct_mnt sbwe)"
ct_track mnt "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
echo before >"$MNT/d/f"
sync
[ "$(info stopped)" = none ] || { fail "setup: the mount is already stopped ($(info stopped))"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set sync_writeback_eio 1
RC=0
{ : >"$MNT/d/c1"; } 2>/dev/null || RC=$?
LEFT="$(cat /sys/module/cetrafs/parameters/sync_writeback_eio)"
ct_param_set sync_writeback_eio 0
[ "$LEFT" = 0 ] || { fail "setup: the create reached no synchronous metadata write (knob still $LEFT)"; umount "$MNT"; ct_exit; }
[ "$RC" != 0 ] && pass "the create whose update writeback lost failed" ||
    fail "the create succeeded although its metadata write never reached the device"
[ "$(info stopped)" = error ] && pass "and the mount stopped (stopped: error)" ||
    fail "the mount runs on after a lost metadata write (stopped: $(info stopped))"
dmesg_since "$MARK" | grep -q "the device refused a metadata write" &&
    pass "the kernel says why" || fail "no 'refused a metadata write' line in dmesg"
umount "$MNT" || umount -l "$MNT"
mount -t cetrafs "$DEV" "$MNT" && [ "$(cat "$MNT/d/f")" = before ] &&
    pass "the remount recovers, with the data from before" || fail "the remount did not recover"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
