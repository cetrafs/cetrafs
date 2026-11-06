#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the no-CAW mount gate fences only the incarnation it watched die
#
# A no-CAW mount watches every other registered row for a stale window;
# a row whose hb_seq stood still is fenced and marked departed, and the
# mount goes ahead as the volume's only node. The fence skipped the
# incarnation check every other fence makes: a node re-attaching between
# the gate's last re-read and the fence was marked departed as a live
# node, kept writing until its next tick, and the mount proceeded beside
# it (audit 2026-11-06 L8). The fence is now bound to the hb_seq the
# watch judged.
#
# Staged: a dead peer row; nocaw_fence_stall_ms holds the gate between
# its re-read and the fence, and the row beats in that gap. The mount
# must be refused and the row must not be marked departed.
#
# DISCRIMINATION: unbound, the row is marked departed (last_seen 0) and
# the mount goes ahead.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/nocaw_fence_stall_ms ] || { skip "nocaw_fence_stall_ms is missing"; ct_exit; }
POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 nocawinc)"
MNT="$(ct_mnt nocawinc)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
set_stale_window "$TEST_STALE_SECS"
ct_param_set nocaw_fence_stall_ms 4000

MARK="$(dmesg_mark)"
RC=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null &
MPID=$!
for _ in $(seq 1 40); do
    dmesg_since "$MARK" | grep -qE "waiting ([0-9]+)s to see whether 1 other node" && break
    sleep 0.25
done
W="$(dmesg_since "$MARK" | sed -n 's/.*waiting \([0-9]*\)s to see whether 1 other node.*/\1/p' | head -1)"
[ -n "$W" ] || { fail "setup: the mount never watched the peer row"; wait "$MPID" || true; ct_exit; }
sleep $((W + 1)) # past the watch and its re-read: inside the stall
"$POKE" "$DEV" 1 --beat >/dev/null # the node re-attaches and beats
wait "$MPID" || RC=$?
ct_param_set nocaw_fence_stall_ms 0
LS="$("$POKE" "$DEV" 1 | sed -n 's/.* last_seen=\([0-9]*\) .*/\1/p')"
if mountpoint -q "$MNT"; then
    fail "the mount went ahead beside a node that re-attached before the fence"
    umount "$MNT"
else
    pass "the mount was refused: the row it was about to fence had come back"
fi
[ "${LS:-0}" != 0 ] && pass "the re-attached row was not marked departed" ||
    fail "the gate marked a live incarnation departed (last_seen=0)"
log "mount rc=$RC; $(dmesg_since "$MARK" | grep -oE 'node 1 came back[^-]*' | head -1)"
ct_exit
