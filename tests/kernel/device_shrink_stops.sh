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
#
# A revalidate in flight is not a shrink: a plain sd device whose READ
# CAPACITY fails in a controller failover reads 0 until the next good
# one, and one sample stopped -- under errors=panic, panicked -- the host
# (audit 2026-11-15 F-39). Faked samples (device_size_fake_ticks):
#   Z. three samples of 0: the mount runs on;
#   T. one short sample, then the real size: the mount runs on.
# DISCRIMINATION: device_shrink_one_sample=1 -- each stops the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# A device per round: a stopped mount leaves its row registered, and a
# later mkfs on the same device would watch it out first.
fresh() { IMG="$(ct_image 560 "dshrink$1")"; DEV="$(ct_loop "$IMG")"; }
MNT="$(ct_mnt dshrink)"
ct_track mnt "$MNT"
ct_param_set device_shrink_ignored 0
ct_param_set device_shrink_one_sample 0
ct_param_set device_size_fake_ticks 0
ct_param_set device_size_fake_blocks 0
compress_timing
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <ignored 0|1> -> RES
round() {
    local size mark st said=no after=fail
    fresh "$1"
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

# <tag> <0|short> <ticks> <one_sample 0|1> -> TRES (stopped=...)
transient() {
    local need mark n
    fresh "$1"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    need=$(($(blockdev --getsize64 "$DEV") / 4096))
    [ "$2" = 0 ] && n=0 || n=$((need - 1))
    echo "$4" >/sys/module/cetrafs/parameters/device_shrink_one_sample
    echo "$n" >/sys/module/cetrafs/parameters/device_size_fake_blocks
    mark="$(dmesg_mark)"
    echo "$3" >/sys/module/cetrafs/parameters/device_size_fake_ticks
    # A stopped mount's tick takes no more samples: that ends it too.
    wait_for 20 '[ "$(cat /sys/module/cetrafs/parameters/device_size_fake_ticks)" = 0 ] ||
        [ "$(sed -n "s/^stopped: //p" "$(ct_procdir "$DEV")/info")" != none ]' ||
        { fail "setup: the faked samples were never taken"; ct_exit; }
    sleep 4 # more ticks on the real size
    TRES="stopped=$(sed -n 's/^stopped: //p' "$(ct_procdir "$DEV")/info") faked=$(dmesg_since "$mark" | grep -c 'device size sample faked' || true)"
    echo 0 >/sys/module/cetrafs/parameters/device_shrink_one_sample
    echo 0 >/sys/module/cetrafs/parameters/device_size_fake_ticks
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
}

transient z 0 3 0
Z="$TRES"
transient zc 0 3 1
ZC="$TRES"
transient t short 1 0
T="$TRES"
transient tc short 1 1
TC="$TRES"
log "Z: $Z; control: $ZC"
log "T: $T; control: $TC"
[ "$(field stopped "$Z")" = none ] && [ "$(field faked "$Z")" = 3 ] &&
    pass "Z: three zero-size samples did not stop the mount ($Z)" || fail "Z: $Z"
[ "$(field stopped "$T")" = none ] && [ "$(field faked "$T")" = 1 ] &&
    pass "T: one short sample did not stop the mount ($T)" || fail "T: $T"
[ "$(field stopped "$ZC")" = error ] && [ "$(field stopped "$TC")" = error ] && [ "$(field faked "$ZC")" = 1 ] &&
    pass "control: as before, one sample stopped the mount (Z $ZC, T $TC)" ||
    fail "control: Z $ZC, T $TC -- the faked samples did not reach the check"

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
