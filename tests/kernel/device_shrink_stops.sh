#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a LUN shrunk under a live mount stops it
#
# The device's size was checked at mount and when a peer's grow was
# adopted, and nowhere else: a LUN shrunk under a live mount was never
# noticed, and every block past the new end failed one I/O at a time
# (audit 2026-11-15 M-45). The heartbeat now compares the two each tick.
#
# The loop device's backing file loses its last block and the loop
# device is told (losetup -c):
#   1. the mount stops (procfs "stopped: error") within a few beats,
#      saying why;
#   2. with the size put back, the volume mounts again and writes.
#
# DISCRIMINATION: device_shrink_ignored=1 -- the mount runs on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IMG="$(ct_image 560 dshrink)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dshrink)"
ct_track mnt "$MNT"
ct_param_set device_shrink_ignored 0
ct_param_set hb_interval_secs 2
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <ignored 0|1> -> RES
round() {
    local size mark st said=no after=fail
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo x >"$MNT/f"
    sync
    echo "$2" >/sys/module/cetrafs/parameters/device_shrink_ignored
    size="$(stat -c %s "$IMG")"
    mark="$(dmesg_mark)"
    truncate -s $((size - 4096)) "$IMG"
    losetup -c "$DEV"
    [ "$(blockdev --getsize64 "$DEV")" -lt "$size" ] ||
        { fail "setup: the loop device did not shrink"; ct_exit; }
    wait_for 12 '[ "$(sed -n "s/^stopped: //p" "$(ct_procdir "$DEV")/info")" != none ]' || true
    st="$(sed -n 's/^stopped: //p' "$(ct_procdir "$DEV")/info")"
    dmesg_since "$mark" | grep -q "the device shrank under the mount" && said=yes
    echo 0 >/sys/module/cetrafs/parameters/device_shrink_ignored
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    truncate -s "$size" "$IMG"
    losetup -c "$DEV"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        echo y >"$MNT/g" && sync && after=ok
        umount "$MNT"
    fi
    RES="stopped=$st said=$said after=$after"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (a shrink ignored): $C"
[ "$(field stopped "$F")" = error ] && [ "$(field said "$F")" = yes ] &&
    pass "1: the shrunk device stopped the mount, saying why ($F)" || fail "1: $F"
[ "$(field after "$F")" = ok ] && pass "2: with the size back, the volume mounted and wrote ($F)" || fail "2: $F"
[ "$(field stopped "$C")" = none ] &&
    pass "control: as before, the mount ran on over a shrunk device ($C)" ||
    fail "control: $C -- something else stopped the mount"
ct_exit
