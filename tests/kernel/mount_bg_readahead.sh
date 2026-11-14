#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount reads the Block Group table ahead, not one descriptor at a time
#
# The layout walk read every Block Group descriptor with its own
# synchronous round trip: 65,536 serial reads before a 64 TiB volume
# mounted (audit 2026-11-14 P4). It now reads each window of 256 ahead
# as one plugged batch.
#
# A 1 TiB sparse volume (2048 groups of 512 MiB) is mounted; the loop
# device's completed reads during the mount are counted:
#   1. it mounts and a file written to it reads back;
#   2. the descriptor walk took a few dozen reads, not one per group.
#
# DISCRIMINATION: mount_bg_ra_off reads each descriptor on its own.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/mount_bg_ra_off ] || { skip "mount_bg_ra_off is missing"; ct_exit; }
MNT="$(ct_mnt mbr)"
ct_track mnt "$MNT"
ct_param_set mount_bg_ra_off 0
P=/sys/module/cetrafs/parameters

# <off 0|1> -> "<reads during the mount> <ok|bad>"
probe() {
    local img dev r0 r1 ok
    img="$(ct_image 1048576 "mbr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 4 -b 512 -J 0 -N 1024 -f >/dev/null
    echo "$1" >$P/mount_bg_ra_off
    echo 3 >/proc/sys/vm/drop_caches
    r0="$(awk '{print $1}' "/sys/block/$(basename "$dev")/stat")"
    ct_mount "$dev" "$MNT"
    r1="$(awk '{print $1}' "/sys/block/$(basename "$dev")/stat")"
    echo 0 >$P/mount_bg_ra_off
    echo hello >"$MNT/f"
    sync
    [ "$(cat "$MNT/f")" = hello ] && ok=ok || ok=bad
    ct_umount "$MNT" >/dev/null
    echo "$((r1 - r0)) $ok"
}
read -r R OK <<<"$(probe 0)"
read -r R0 _ <<<"$(probe 1)"
log "mounting 2048 Block Groups: $R reads read ahead, $R0 one by one"
[ "$OK" = ok ] && pass "1: the volume mounts and a file reads back" || fail "1: the volume did not work after the mount"
[ "$R0" -ge 2048 ] || fail "setup: the one-by-one mount took only $R0 reads -- the table was not read from the device"
# The rest of the mount (records, the claim's reconcile) reads the same
# in both runs, and one by one the walk is one read per group; so the
# walk read ahead cost R - (R0 - 2048).
W=$((R - (R0 - 2048)))
log "the descriptor walk read ahead: $W reads"
[ "$W" -le 64 ] && pass "2: the walk took $W reads for 2048 groups" ||
    fail "2: the walk took $W reads for 2048 groups -- still about one per descriptor"
[ $((R0 - R)) -ge 1900 ] && pass "control: one by one the mount takes $R0, $((R0 - R)) more -- the suite discriminates" ||
    fail "control: $R0 against $R -- the suite cannot tell"
ct_exit
