#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer is judged against ITS tick rate, not against ours
#
# Liveness here is "has this peer's hb_seq stopped advancing for long
# enough". The window used to be entirely the observer's own stale_secs,
# which says how long WE are willing to wait and nothing at all about how
# often the other node actually beats.
#
# So two nodes configured differently -- a different build, a tuned
# deployment, or a test that compressed the parameters on one node and
# not the other -- end with the impatient one declaring a perfectly
# healthy peer dead: breaking its namespace locks, stealing its zone
# groups and fencing it. That is the same class of failure as the
# wall-clock staleness bug, which cost 85 of 200 directory entries on
# real hardware: a liveness decision resting on something the deciding
# node could not actually see.
#
# Each node now publishes its own heartbeat period in its registry row
# (taken from the zero-filled reserved area, so no format change), and an
# observer floors its window at four of the PEER's beats.
#
# Measured discrimination: with the floor removed, the slow peer comes
# back "stale=yes" -- which in a real cluster is the observer about to
# break that node's namespace locks, steal its zone groups and fence it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 ptr)"
MNT="$(ct_mnt ptr)"
ct_mkfs_small "$DEV" >/dev/null

log "checking this node advertises its own heartbeat period"
compress_timing            # 1s ticks, so the advertised value is distinctive
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
sleep $((TEST_HB_SECS * 3))
ct_umount "$MNT"
reset_stale_window
ADV="$("$NODE_POKE" "$DEV" 0 | grep -oP 'hb_interval=\K[0-9]+' || echo "")"
if [ -n "$ADV" ]; then
    [ "$ADV" = "$TEST_HB_SECS" ] &&
        pass "peer rate: the row advertises this node's actual period (${ADV}s)" ||
        fail "peer rate: row advertises ${ADV}s, this node runs ${TEST_HB_SECS}s"
else
    skip "peer rate: node_poke does not print hb_interval; relying on the behaviour check below"
fi

log "checking a SLOW peer is not declared dead by an impatient observer"
# A peer that registered, beats every 30s, and was last seen one beat
# ago. An observer configured to give up after 3s must still not call it
# dead: 4 x 30s is the floor.
set_stale_window 3
ct_mount "$DEV" "$MNT"
# Poked AFTER the mount: the no-CAW mount gate would otherwise watch this
# very row for four of its advertised 30s beats before admitting us,
# which is correct of the gate (see mount_gate_no_caw.sh) and nothing to
# do with what this section is about.
"$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" 30 >/dev/null 2>&1 ||
    "$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null
# Give the observer several of ITS OWN windows to get it wrong in.
sleep 8
CLUSTER="$(cat /proc/fs/cetrafs/$(basename "$DEV")/cluster)"
reset_stale_window
if echo "$CLUSTER" | grep -q '^node 1:.*stale=no'; then
    pass "peer rate: a peer beating slower than our window is still judged alive"
else
    fail "peer rate: a slow-but-live peer was declared stale: $(echo "$CLUSTER" | grep '^node 1:')"
fi
ct_umount "$MNT"

ct_exit
