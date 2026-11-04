#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim whose renewals stall is not judged dead before a node would be
#
# A mount watched a repair claim for three renewals (15 s) and called a
# still one dead. A node is given 120 s, because multipath queues I/O
# behind dead paths for up to 90 s and the heartbeat waits in that queue
# too; a repairer's renewal is a pwrite+fdatasync from a timer, queued
# exactly the same way. So a repairer whose host lost its paths for
# 15..90 s was judged dead by a mount on a healthy host, which then came
# up under a repair whose blind writes were still queued to land.
#
# Staged: a REPAIR row renewed once, then silent for 40 s (the stall),
# then renewing again. A mount started during the stall must refuse.
# The stale window is set to 60 s, above the stall.
#
# DISCRIMINATION: with the 15 s watch the mount comes up mid-stall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 rpstall)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rpstall)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_param_set stale_secs 60
"$NODE_POKE" "$IMG" 1 2 aa "$(date +%s)" >/dev/null
grep -q 'state=2 ' <<<"$("$NODE_POKE" "$IMG" 1)" || { fail "setup: no REPAIR row planted"; ct_exit; }

# The repairer: one renewal, a 40 s stall, then renewing again. Longer
# than the old watch before registration and the one after it together.
(
    "$NODE_POKE" "$IMG" 1 --beat >/dev/null 2>&1
    sleep 40
    for _ in $(seq 1 90); do "$NODE_POKE" "$IMG" 1 --beat >/dev/null 2>&1 || true; sleep 1; done
) &
BEATER=$!
ct_track cmd "kill $BEATER"
sleep 1

MARK="$(dmesg_mark)"
T0="$(date +%s)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    T="$(( $(date +%s) - T0 ))"
    ct_umount "$MNT"
    fail "the mount came up ${T}s into a 40 s renewal stall -- under a live repair"
else
    T="$(( $(date +%s) - T0 ))"
    dmesg_since "$MARK" | grep -q 'is being repaired' &&
        pass "the mount refused after ${T}s: the repair renewed again inside the window" ||
        fail "the mount failed (${T}s) but not on the repair claim: $(dmesg_since "$MARK" | grep -i refus | tail -1)"
fi
kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true
ct_exit
