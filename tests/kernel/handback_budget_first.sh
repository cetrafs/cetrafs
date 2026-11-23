#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a hand-back pass over budget leaves the remaining empty groups untouched
#
# Each heartbeat pass hands back empty Block Groups, discarding each
# within a budget. The budget was tested by the discard itself -- after
# the group had been drained, flushed, scanned, flagged on the device by
# one swap and, deferred, unflagged by another. Every deferred group
# paid all of that for nothing and again on the next pass: compare-and-
# swaps per tick that grew with the number of empty groups (audit
# 2026-11-22 N-37). The budget is now tested before the group's work.
#
# About ten empty Block Groups held back, then released with a 1 ms
# budget and every discard stalled 50 ms -- one group per pass, the rest
# deferred:
#   1. groups are deferred, and the CAS operations of the passes stay
#      below one per deferred group.
#
# DISCRIMINATION: handback_budget_late=1 (as before): at least two CAS
# per deferred group (the flag set, and its clear).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in handback_budget_late handback_budget_ms discard_issue_stall_ms bg_release_off; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt hbbf)"
ct_track mnt "$MNT"
for k in handback_budget_late handback_budget_ms discard_issue_stall_ms bg_release_off; do
    ct_param_set "$k" "$(cat $P/$k)"
done
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <late 0|1> -> RES "deferred= cas= handed="
round() {
    local img dev proc c0 d0 h0
    img="$(ct_big_image 5800 "hbbf$1")"
    dev="$(ct_loop "$img")"
    [ "$(cat "/sys/block/$(basename "$dev")/queue/discard_max_bytes")" != 0 ] ||
        { skip "this loop device takes no discards"; ct_exit; }
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_param_set bg_release_off 1
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    info() { awk -v k="$1:" '$1 == k { print $2 }' "$proc/info"; }
    ct_param_set handback_budget_late "$2"
    ct_param_set handback_budget_ms 1
    ct_param_set discard_issue_stall_ms 50
    sleep 1
    c0="$(info cas_ops)"; d0="$(info discard_handback_deferred)"; h0="$(info discard_handback_bgs)"
    ct_param_set bg_release_off 0
    sleep 6
    ct_param_set bg_release_off 1
    sleep 1
    RES="deferred=$(($(info discard_handback_deferred) - d0)) cas=$(($(info cas_ops) - c0))"
    RES="$RES handed=$(($(info discard_handback_bgs) - h0))"
    ct_param_set discard_issue_stall_ms 0
    ct_param_set handback_budget_ms 0
    ct_param_set handback_budget_late 0
    ct_umount "$MNT"
    losetup -d "$dev" 2>/dev/null || true
    rm -f "$img"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (budget tested late): $C"
[ "$(get deferred "$R")" -ge 5 ] && [ "$(get deferred "$C")" -ge 5 ] && [ "$(get handed "$R")" -ge 1 ] ||
    { fail "setup: too few groups deferred, or none handed back ($R / $C)"; ct_exit; }
[ "$(get cas "$R")" -lt "$(get deferred "$R")" ] &&
    pass "1: $(get deferred "$R") deferrals cost $(get cas "$R") CAS in all -- under one each" || fail "1: $R"
[ "$(get cas "$C")" -ge $((2 * $(get deferred "$C"))) ] &&
    pass "control: tested late, $(get deferred "$C") deferrals cost $(get cas "$C") CAS -- two or more each" ||
    fail "control: $C -- the late budget is not what costs the swaps here"
ct_exit
