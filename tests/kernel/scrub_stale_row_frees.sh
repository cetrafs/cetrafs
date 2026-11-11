#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# without CAW, a stale row with frees in flight still keeps the scrub out
#
# The scrub abandons a cycle while any registry row says frees are in
# flight -- except a stale row's, on the premise that a stale node's
# frees never land: it stopped writing when its lease ran out, before any
# peer could call it stale. The lease is armed on CAW mounts only. On a
# device without CAW the mount gate admits a second node exactly when
# the first LOOKS dead, and one that only stalled resumes its frees until
# its next heartbeat finds the fence -- over blocks the scrub, told the
# row was quiet, had already freed (audit 2026-11-11 N4).
#
# The rig: a loop mount (no CAW) with a second registered row that is
# stale (departure dead) and has frees_inflight set; the scrub runs.
#
#  1. no scrub cycle completes; cycles are skipped for frees in flight.
#  2. once the row is gone, cycles complete again.
#
# DISCRIMINATION (2026-11-11, node.c before this fix): 1 completes
# cycles beside the stale row.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

DEV="$(ct_dev 600 scrnocaw)"
MNT="$(ct_mnt scrnocaw)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
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
sleep 9
C1="$(done_c)"; K1="$(skip_c)"
[ $((C1 - C0 + K1 - K0)) -gt 0 ] || { ct_param_set scrub 0; fail "setup: no scrub cycle ran in 9 s"; ct_exit; }
[ "$C1" = "$C0" ] && pass "1: no cycle completed beside the stale row with frees in flight ($((K1 - K0)) skipped)" ||
    fail "1: $((C1 - C0)) cycle(s) completed beside a stale row whose frees may still land"

"$NPOKE" "$DEV" 1 0 00 0 >/dev/null
wait_for 30 '[ "$(sed -n "s/^scrub_cycles: //p" "'"$PROC/info"'")" -gt '"$C1"' ]' &&
    pass "2: with the row gone, cycles complete again" || fail "2: no cycle completed in 30 s after the row was cleared"
ct_param_set scrub 0
ct_umount "$MNT"
ct_exit
