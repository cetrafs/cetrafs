#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new mount is never handed a stopped, lazily unmounted superblock
#
# A stopped mount whose files are still open (a VM still running on it)
# cannot be unmounted; umount -l detaches it and keeps the superblock
# alive for those files. A mount of the same device then found that
# superblock and reused it: mount success logged, every I/O EIO, and the
# node never rejoined (audit 2026-11-15 BM-44).
#
# A mount is stopped (controls shutdown=now) with a file held open, then
# lazily unmounted, then mounted again:
#   1. the mount is refused while the old superblock lives, saying why;
#   2. once the file is closed, a mount gets a fresh superblock and
#      writes; fsck clean.
#
# DISCRIMINATION: mount_reuse_stopped=1 -- the second mount reuses the
# stopped superblock and reports success.
# The fresh mount re-attaches a row that never departed, which waits out
# the stale window (120 s): two rounds, hence the limit.
# ct-timeout: 480
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
DEV="$(ct_dev 560 mreuse)"
MNT="$(ct_mnt mreuse)"
ct_track mnt "$MNT"
ct_param_set mount_reuse_stopped 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <reuse 0|1> -> RES
round() {
    local mark log ok=no said=no after=fail
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo x >"$MNT/f"
    exec 8<"$MNT/f"
    echo shutdown=now >"$(ct_procdir "$DEV")/controls"
    umount -l "$MNT"
    echo "$2" >/sys/module/cetrafs/parameters/mount_reuse_stopped
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && ok=yes
    echo 0 >/sys/module/cetrafs/parameters/mount_reuse_stopped
    log="$(dmesg_since "$mark")"
    grep -q "mount success" <<<"$log" && ok=yes
    grep -q "previous mount of the volume is stopped" <<<"$log" && said=yes
    umount "$MNT" 2>/dev/null || true
    exec 8<&-
    # The last file closed: the stopped superblock goes away.
    sleep 1
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        echo y >"$MNT/g" && sync && after=ok
        umount "$MNT"
    fi
    RES="reused=$ok said=$said after=$after fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (a stopped superblock reused): $C"
[ "$(field reused "$F")" = no ] && [ "$(field said "$F")" = yes ] &&
    pass "1: the mount was refused while the stopped superblock lived, saying why ($F)" || fail "1: $F"
[ "$(field after "$F")" = ok ] && [ "$(field fsck_err "$F")" = 0 ] &&
    pass "2: once the file closed, a fresh mount wrote; fsck clean ($F)" || fail "2: $F"
[ "$(field reused "$C")" = yes ] && [ "$(field said "$C")" = no ] &&
    pass "control: as before, the stopped superblock was handed out again ($C)" ||
    fail "control: $C -- the second mount did not find the stopped superblock"
ct_exit
