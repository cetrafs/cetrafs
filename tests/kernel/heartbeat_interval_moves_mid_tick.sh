#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a heartbeat interval lowered mid-tick does not self-fence a healthy node
#
# A tick re-arms the next one first, with the interval as it reads then,
# and bounds the renewal's lease by the interval as it reads after the
# fence pre-check's device read. A controls write lowering the interval
# in between (30 -> 5) left a lease of 3 x 5 = 15 s against a next
# renewal 30 s away: the node self-fenced at +15 s while perfectly
# healthy (audit 2026-11-05, N6). Unavailability, not data loss -- a
# whole host's VMs losing their datastore.
#
# Staged with lease_force (the loop rig has no CAW, where the lease is
# otherwise off), a 5 s beat raised to 30 through controls, and
# hb_tick_stall_ms holding the next tick right after its re-arm while
# controls lowers it back to 5. 20 s after that tick the mount must still
# be up and writable.
#
# DISCRIMINATION: proven 2026-11-05 with the lease bounded and the tick
# armed as before (stall kept): the mount stops on its lease ~15 s after
# the tick.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in lease_force hb_tick_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

DEV="$(ct_dev 560 hbmid)"
MNT="$(ct_mnt hbmid)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 5
ct_param_set stale_secs 120
ct_param_set lease_force 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
ctl() { echo "$1" >"$PROC/controls"; }
stopped() { sed -n 's/^stopped: //p' "$PROC/info"; }

ctl "hb_interval_secs 30" || { fail "setup: controls refused hb_interval_secs 30"; ct_exit; }
ct_param_set hb_tick_stall_ms 2500
# The first tick (5 s after the mount) takes the stall: the knob reads 0
# from the moment it does.
for _ in $(seq 1 100); do
    [ "$(cat /sys/module/cetrafs/parameters/hb_tick_stall_ms)" = 0 ] && break
    sleep 0.1
done
[ "$(cat /sys/module/cetrafs/parameters/hb_tick_stall_ms)" = 0 ] ||
    { fail "setup: no tick reached the stall within 10 s"; ct_exit; }
sleep 0.5
ctl "hb_interval_secs 5" || { fail "setup: controls refused hb_interval_secs 5 mid-tick"; ct_exit; }
pass "setup: the tick re-armed at 30 s and the interval went back to 5 s under it"

sleep 20
S="$(stopped)"
[ "$S" = none ] && pass "20 s later the mount is still up (stopped: $S)" ||
    fail "the node fenced itself on its own lease although healthy (stopped: $S)"
echo after >"$MNT/after" 2>/dev/null && sync && pass "and accepts writes" ||
    fail "a write fails 20 s after the interval moved"
ct_umount "$MNT"
ct_exit
