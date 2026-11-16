#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# unmount keeps the lease renewed while it waits for a maintenance pass
#
# Unmount stopped the heartbeat's lease renewal first and then waited for
# its maintenance pass, which can block on the device for as long as it
# likes. With the renewal gone the lease ran out during the wait: the
# mount self-fenced, could not record its clean departure, and its peers
# could reclaim from it while it still wrote (audit 2026-11-15 BM-23).
# The maintenance pass is now stopped first, with the renewal running.
#
# Every maintenance pass is held 8 s (hb_maint_delay_ms) on compressed
# timing, so one is mid-stall when the unmount comes:
#   fixed:   no lapse, and the row records a clean departure;
#   control: hb_stop_tick_first=1 -- the lease lapses during the unmount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
IMG="$(ct_image 560 umlease)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt umlease)"
ct_track mnt "$MNT"
ct_param_set hb_maint_delay_ms 0
ct_param_set hb_stop_tick_first 0
compress_timing
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <tick_first 0|1> -> RES
round() {
    local me mark log
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo x >"$MNT/f"
    me="$(sed -n 's/^node \([0-9]*\): .*(this node)$/\1/p' "$(ct_procdir "$DEV")/cluster")"
    echo "$2" >/sys/module/cetrafs/parameters/hb_stop_tick_first
    echo 8000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep $((TEST_HB_SECS * 2 + 1)) # a pass is in its stall
    mark="$(dmesg_mark)"
    umount "$MNT"
    log="$(dmesg_since "$mark")"
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    echo 0 >/sys/module/cetrafs/parameters/hb_stop_tick_first
    grep -qiE "lease expired|SELF-FENCED" <<<"$log" && RES="lapse=yes" || RES="lapse=no"
    RES="$RES departure=$(field departure "$("$NPOKE" "$DEV" "$me")")"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (renewal stopped first): $C"
[ "$(field lapse "$F")" = no ] && [ "$(field departure "$F")" = 1 ] &&
    pass "fixed: the lease held through the unmount, and it recorded a clean departure ($F)" || fail "fixed: $F"
[ "$(field lapse "$C")" = yes ] &&
    pass "control: as before, the lease lapsed while the unmount waited ($C)" ||
    fail "control: no lapse -- the suite does not reach the wait: $C"
ct_exit
