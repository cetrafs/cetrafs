#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a re-attaching node hands back its dead incarnation's replay claims, and beats while its mount waits
#
# A replay claim names the replaying node's registry row. A node that
# crashed mid-replay and came back re-attached that row and beat again,
# so its old claim read as a LIVE replayer's: the area's owner waited
# 3*stale+30 s on a claim nobody would release and failed its mount
# -EBUSY (audit R19a). The re-attach now hands back every claim naming
# its row before it replays anything -- leaving the area DIRTY, since
# the replay it protected may be half done.
#
# And between registration and the first heartbeat tick a mount has no
# beat at all, while it may wait minutes on a replay claim: every peer
# could judge it stale and fence it before it did anything (R19b). Such
# a wait now renews the row.
#
# DISCRIMINATION: A with journal_sweep_skip=1 leaves the claim on the
# device; B against a build without the mount beat sees hb_seq stand
# still for the whole wait.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_sweep_skip ] || { skip "journal_sweep_skip is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
NPOKE="$(ct_helper node_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 rcreatt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rcreatt)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 4))
ct_umount "$MNT"

# plant_and_remount: our row looks crashed, and holds the replay claim on
# PEER's area (DIRTY), as an incarnation that died mid-replay leaves it.
# Prints the area's state after the remount.
plant_and_remount() {
    "$JPOKE" "$DEV" "$PEER" --claim "$NID" >/dev/null
    "$NPOKE" "$DEV" "$NID" --beat >/dev/null
    blockdev --flushbufs "$DEV"
    grep -q "replay_owner=$NID " <<<"$("$JPOKE" "$DEV" "$PEER" --dump)" ||
        { fail "setup: the planted claim is not on the device"; ct_exit; }
    ct_mount "$DEV" "$MNT"
    "$JPOKE" "$DEV" "$PEER" --dump
    ct_umount "$MNT"
}

log "A: the previous incarnation's claim on node $PEER's area"
D="$(plant_and_remount)"
log "after the re-attach: $D"
grep -q "replay_owner=65535 " <<<"$D" && pass "A: the re-attach handed the claim back" ||
    fail "A: the dead incarnation's claim still names row $NID: $D"
grep -q "^state=1 " <<<"$D" && pass "A: and left the area DIRTY for whoever replays it next" ||
    fail "A: the area is no longer dirty: $D"

ct_param_set journal_sweep_skip 1
D="$(plant_and_remount)"
ct_param_set journal_sweep_skip 0
grep -q "replay_owner=$NID " <<<"$D" && pass "A control: without the sweep the claim survives the re-attach" ||
    fail "A control: the claim went away without the sweep -- something else clears it, A proves nothing: $D"
"$JPOKE" "$DEV" "$PEER" --claim release >/dev/null

log "B: a mount waiting on a replay claim keeps beating"
# A live foreign claim on our own area holds the mount in its attach
# (as journal_attach_wait.sh); our row must keep moving meanwhile.
"$JPOKE" "$DEV" "$NID" --claim "$PEER" >/dev/null
blockdev --flushbufs "$DEV"
ct_param_set force_live_replay_claim 1
mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
sleep 2
S1="$("$NPOKE" "$DEV" "$NID" | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p')"
sleep 7
S2="$("$NPOKE" "$DEV" "$NID" | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p')"
STILL=0; kill -0 "$MPID" 2>/dev/null && ! mountpoint -q "$MNT" && STILL=1
"$JPOKE" "$DEV" "$NID" --claim release >/dev/null
blockdev --flushbufs "$DEV"
wait "$MPID" || fail "B: the mount failed after the claim was released"
ct_param_set force_live_replay_claim 0
[ "$STILL" = 1 ] || fail "setup: the mount was not waiting on the claim"
log "B: hb_seq $S1 -> $S2 across 7 s of waiting (interval 2 s)"
[ -n "$S1" ] && [ -n "$S2" ] && [ "$S2" -gt "$S1" ] &&
    pass "B: the waiting mount renewed its row" ||
    fail "B: the row stood still while the mount waited ($S1 -> $S2) -- a peer would judge it dead"
mountpoint -q "$MNT" && ct_umount "$MNT"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
