#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount that stopped while mounting is refused, not reported as mounted
#
# Some mount phases only log their own failure -- the pending-free drain,
# a dead grow's heal -- and a fatal error inside one (a refused metadata
# write, an undecidable swap) stops the mount on the way. fill_super went
# on and returned success: the caller got a mount failing every I/O with
# EIO, and the error that stopped it was gone (audit 2026-11-15 BM-20).
#
# A fatal error is raised at fail point 8, once procfs is published
# (mount_fatal_at=8), and the mount carries on. Earlier, a later phase
# trips over the stop by accident (the root inode's read fails EIO); from
# here only phases that log their failure are left:
#   1. the mount fails, saying why;
#   2. the volume mounts normally afterwards; fsck clean.
#
# DISCRIMINATION: mount_stopped_ok=1 -- the kernel reports the same,
# stopped, mount as mounted OK.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
DEV="$(ct_dev 560 mstopped)"
MNT="$(ct_mnt mstopped)"
ct_track mnt "$MNT"
ct_param_set mount_fatal_at 0
ct_param_set mount_stopped_ok 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <stopped_ok 0|1> -> RES
round() {
    local mark log
    ct_mkfs_small "$DEV" >/dev/null
    echo "$2" >/sys/module/cetrafs/parameters/mount_stopped_ok
    echo 8 >/sys/module/cetrafs/parameters/mount_fatal_at
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || true
    echo 0 >/sys/module/cetrafs/parameters/mount_fatal_at
    echo 0 >/sys/module/cetrafs/parameters/mount_stopped_ok
    log="$(dmesg_since "$mark")"
    grep -q "TEST: fatal error at mount stage 8" <<<"$log" ||
        { fail "setup: the fatal error was never raised"; ct_exit; }
    # What the KERNEL said: mount(8) fails a stopped mount's follow-up
    # calls by itself, with an EPERM that names nothing.
    umount "$MNT" 2>/dev/null || true
    grep -q "mounted OK" <<<"$log" && RES="mounted=yes" || RES="mounted=no"
    grep -q "the mount stopped while mounting" <<<"$log" && RES="$RES said=yes" || RES="$RES said=no"
    ct_mount "$DEV" "$MNT"
    echo x >"$MNT/f" && sync && RES="$RES after=ok" || RES="$RES after=fail"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (a stopped mount reported mounted): $C"
[ "$(field mounted "$F")" = no ] && [ "$(field said "$F")" = yes ] &&
    pass "1: the stopped mount was refused, saying why ($F)" || fail "1: $F"
[ "$(field after "$F")" = ok ] && [ "$(field fsck_err "$F")" = 0 ] &&
    pass "2: the volume mounted and wrote afterwards; fsck clean ($F)" || fail "2: $F"
[ "$(field mounted "$C")" = yes ] && [ "$(field said "$C")" = no ] &&
    pass "control: as before, the kernel reported the stopped mount as mounted ($C)" ||
    fail "control: $C -- the fatal error did not stop the mount"
ct_exit
