#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a publish whose cache flush the device refused stops the mount AND reports the failure
#
# Every extent-map publish (truncate, punch, fallocate, defrag) flushes
# the device cache after its swap, so the frees that follow cannot reach
# the device first. A refused flush stops the mount -- the publish
# landed, its durability is unknown -- and the publish then returned
# success: a punch or a fallocate told its caller it was done (audit
# 2026-11-15 BL-79). It now returns EIO. (A truncate is not the probe:
# what it does after the publish fails on a stopped mount anyway.)
#   setup: the flush was refused and the mount stopped;
#   1. the punch failed.
#
# DISCRIMINATION: fd_post_flush_stop_ok=1 -- the punch reports success
# on the stopped mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in fd_post_flush_fail fd_post_flush_stop_ok; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt pfref)"
ct_track mnt "$MNT"
ct_param_set fd_post_flush_fail 0
ct_param_set fd_post_flush_stop_ok 0

# <stop_ok 0|1> -> "stopped= rc="
round() {
    local img dev proc mark stopped=0 rc=0
    img="$(ct_image 560 "pfref$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=4 conv=fsync status=none
    echo "$1" >/sys/module/cetrafs/parameters/fd_post_flush_stop_ok
    mark="$(dmesg_mark)"
    echo 1 >/sys/module/cetrafs/parameters/fd_post_flush_fail
    fallocate -p -o 0 -l $((1 << 20)) "$MNT/f" 2>/dev/null || rc=$?
    echo 0 >/sys/module/cetrafs/parameters/fd_post_flush_fail
    echo 0 >/sys/module/cetrafs/parameters/fd_post_flush_stop_ok
    dmesg_since "$mark" | grep -q "refused a cache flush after a publish" &&
        [ "$(sed -n 's/^fenced: //p' "$proc/info")" = yes ] && stopped=1
    umount "$MNT" || umount -l "$MNT"
    echo "stopped=$stopped rc=$rc"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "reported: $R"
C="$(round 1)"
log "control (success reported): $C"
for v in "$R" "$C"; do
    [ "$(get stopped "$v")" = 1 ] || { fail "setup: the refused flush did not stop the mount ($v)"; ct_exit; }
done
pass "setup: the flush after the punch's publish was refused, and the mount stopped"
[ "$(get rc "$R")" != 0 ] && pass "1: the punch failed" || fail "1: the punch reported success ($R)"
[ "$(get rc "$C")" = 0 ] && pass "control: reporting success, the punch said it was done on a stopped mount" ||
    fail "control: the punch failed anyway -- the suite does not reach the publish ($C)"
ct_exit
