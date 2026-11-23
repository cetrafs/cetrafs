#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stale row's frees in flight do not stall the scrub; a live row's do
#
# The scrub abandons a cycle while any registry row says frees are in
# flight -- except a stale row's, on the premise that a stale node's
# frees never land: it stopped writing when its lease ran out, before any
# peer could call it stale. The lease was armed on CAW mounts only, so
# N4 (audit 2026-11-11) kept a stale row busy on a mount without CAW --
# and nothing ever clears it, so the scrub there stalled for the life of
# the volume (review E1). The lease is now armed on every mount
# (lease_expiry.sh runs on this no-CAW loop device), and the exception
# holds in both modes.
#
# The rig: a loop mount (no CAW) with a second registered row that has
# frees_inflight set; the scrub runs.
#
#  1. the row stale (departure dead): cycles complete.
#  2. control: the same row beating -- live: no cycle completes.
#
# DISCRIMINATION (2026-11-11, node.c with N4's no-CAW case): 1 completes
# no cycle.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

DEV="$(ct_dev 600 scrnocaw)"
MNT="$(ct_mnt scrnocaw)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
grep -q 'available=no' "$PROC/properties" || { fail "setup: the loop device is driven with CAW"; ct_exit; }
ct_param_set auto_defrag 0
done_c() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }
skip_c() { sed -n 's/^scrub_inflight_skips: //p' "$PROC/info"; }

"$NPOKE" "$DEV" 1 1 bb $(($(date +%s) - 3600)) >/dev/null
"$NPOKE" "$DEV" 1 --depart 2 >/dev/null
"$NPOKE" "$DEV" 1 --frees 1 >/dev/null
grep -q 'state=1 .*departure=2' <<<"$("$NPOKE" "$DEV" 1)" || { fail "setup: the row was not planted: $("$NPOKE" "$DEV" 1)"; ct_exit; }

C0="$(done_c)"; K0="$(skip_c)"
ct_param_set scrub 1
wait_for 30 '[ "$(sed -n "s/^scrub_cycles: //p" "'"$PROC/info"'")" -gt '"$C0"' ]' &&
    pass "1: cycles complete beside a stale row with frees in flight" ||
    fail "1: no cycle completed in 30 s beside a stale row ($(($(skip_c) - K0)) skipped for frees in flight)"

log "2: the same row, beating"
( for _ in $(seq 1 40); do "$NPOKE" "$DEV" 1 --beat >/dev/null 2>&1 || true; sleep 0.5; done ) &
B=$!
sleep 3
C1="$(done_c)"; K1="$(skip_c)"
sleep 9
C2="$(done_c)"; K2="$(skip_c)"
kill "$B" 2>/dev/null || true; wait "$B" 2>/dev/null || true
[ $((K2 - K1)) -gt 0 ] || fail "2 setup: no cycle was skipped for the live row's frees"
[ "$C2" = "$C1" ] && pass "2: no cycle completed beside a live row with frees in flight ($((K2 - K1)) skipped)" ||
    fail "2: $((C2 - C1)) cycle(s) completed beside a live row whose frees are in flight"
"$NPOKE" "$DEV" 1 0 00 0 >/dev/null
ct_param_set scrub 0
ct_umount "$MNT"
ct_exit
