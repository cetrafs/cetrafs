#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the lease renewal keeps its period no matter how long the reclaim takes
#
# A peer decides this node is dead from how long ago it last renewed its
# Node Registry row. That period was therefore the only deadline in the
# heartbeat -- and the tick re-armed itself AFTER doing everything else:
# claiming and releasing Zone Groups, retrying deferred namespace locks,
# draining peers' queued frees, replaying a dead peer's journal. None of
# those has a bound; all of them wait on the device.
#
# So the real renewal period was "interval plus however long the tick
# took". A device answering slowly stretched it past the staleness
# window and a live node got fenced by a peer -- the one failure mode
# the heartbeat exists to prevent.
#
# The renewal now re-arms before it does anything, and the reclaim work
# runs as its own work item. hb_maint_delay_ms stands in for the slow
# device: no single-node rig can make a journal replay take seconds on
# demand.
#
# Measured through hb_seq in the cluster procfs file, which the renewal
# increments once per successful renewal -- counting them over a fixed
# window gives the period directly.
#
# Discrimination: move the re-arm back to the end of the tick, or call
# the reclaim work inline, and the count drops to roughly the window
# divided by (interval + delay).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 hbcadence)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hbcadence)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

INTERVAL=2
DELAY_MS=6000
WINDOW=20

ct_param_set hb_interval_secs "$INTERVAL"
ct_param_set hb_maint_delay_ms "$DELAY_MS"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/cluster"
[ -r "$PROC" ] || fail "no cluster procfs file at $PROC"

seq_now() { sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p' "$PROC" | head -1; }

# The setup has to be real: if hb_seq never moves at all the numbers
# below are meaningless, so prove the heartbeat is running first.
START="$(seq_now)"
sleep $((INTERVAL * 3))
EARLY="$(seq_now)"
[ -n "$START" ] && [ -n "$EARLY" ] ||
    fail "hb_seq is not readable from $PROC -- nothing to measure"
[ "$EARLY" -gt "$START" ] ||
    fail "hb_seq did not move in $((INTERVAL * 3))s -- the heartbeat is not running, so this test proves nothing"

BEFORE="$(seq_now)"
sleep "$WINDOW"
AFTER="$(seq_now)"
RENEWALS=$((AFTER - BEFORE))

# With the renewal on its own clock the ceiling is WINDOW/INTERVAL (10);
# sharing the tick with a 6s maintenance pass it is WINDOW/(INTERVAL+6)
# (2). Half the ideal rate separates them with room for scheduling
# jitter on a loaded test box.
WANT=$((WINDOW / INTERVAL / 2))
echo "renewals in ${WINDOW}s: $RENEWALS (want >= $WANT; sharing the tick with the ${DELAY_MS}ms reclaim gives about $((WINDOW / (INTERVAL + DELAY_MS / 1000))))"

ct_param_set hb_maint_delay_ms 0

[ "$RENEWALS" -ge "$WANT" ] &&
    pass "the lease renewed on its own period while the reclaim pass was busy" ||
    fail "only $RENEWALS renewals in ${WINDOW}s -- the reclaim work is holding the lease's clock, which is how a live node gets fenced"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
