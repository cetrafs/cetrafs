#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a sync stopped during its flushes writes nothing after the stop
#
# sync_fs and unmount asked the fence once, flushed bitmaps, held frees
# and counters, and then ran sync_blockdev(). A lease that ran out in a
# slow flush left what was refused or dirtied meanwhile dirty, and that
# sync -- ahead of the stop's own sweep, which is queued work -- wrote it
# after peers had taken over (audit 2026-11-15 B-30). Each sync_blockdev
# is now preceded by the fence asked again; a stopped mount drops its
# dirt instead (and put_super, told by free_sb_info, does not sync).
#
# The data bitmaps are held off the block device since a3d357f, so the
# dirt is played: sync_test_dirty_lba makes sync_fs dirty the volume's
# last (unused) block after its flushes and then stop the mount -- a
# buffer an operation past its gate left, and a lease that ran out
# during the flushes. The stop sweep is held back (stop_sweep_delay_ms),
# as queued work can be.
#   1. the block is not written: the image after the sync and the
#      unmount is the image before the sync.
#
# DISCRIMINATION: sync_regate_off=1: sync_blockdev writes the block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in sync_regate_off sync_test_dirty_lba stop_sweep_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt ssm)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set stop_sweep_delay_ms 0
ct_param_set sync_test_dirty_lba 0
P=/sys/module/cetrafs/parameters

# <old 0|1> -> "stopped=<yes|no> same=<0|1>"
round() {
    local img dev proc a b stopped
    img="$(ct_image 560 "ssm$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    mkdir "$MNT/d"
    for i in $(seq 1 40); do echo "$i" >"$MNT/d/f$i"; done
    sync -f "$MNT"
    sync -f "$img" 2>/dev/null || true
    a="$(md5sum <"$img")"
    echo "$1" >$P/sync_regate_off
    echo 10000 >$P/stop_sweep_delay_ms
    echo $(($(blockdev --getsz "$dev") / 8 - 1)) >$P/sync_test_dirty_lba
    sync -f "$MNT" 2>/dev/null || true
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    echo 0 >$P/sync_regate_off
    echo 0 >$P/stop_sweep_delay_ms
    echo 0 >$P/sync_test_dirty_lba
    sync -f "$img" 2>/dev/null || true
    b="$(md5sum <"$img")"
    echo "stopped=$stopped same=$([ "$a" = "$b" ] && echo 1 || echo 0)"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (no re-gate): $C"
[ "$(get stopped "$R")" = yes ] && [ "$(get stopped "$C")" = yes ] || { fail "setup: the sync did not stop the mount ($R | $C)"; ct_exit; }
pass "setup: the mount stopped after sync_fs's flushes, with a dirty buffer left"
[ "$(get same "$R")" = 1 ] && pass "1: nothing reached the device after the stop" || fail "1: the image changed after the stop"
[ "$(get same "$C")" = 0 ] && pass "control: without the re-gate the sync wrote the dirty block after the stop" ||
    fail "control: the image did not change without the re-gate -- the suite does not reach the sync"
ct_exit
