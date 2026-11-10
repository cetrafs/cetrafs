#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stale replayer's claim is taken only while it is the incarnation judged
#
# A journal area's replay claim names the replaying node's row. A node
# that finds the claim held by a stale row fences that row and swaps the
# claim to itself. The swap compared the row NUMBER only, so a replayer
# that re-attached and claimed the area again was displaced -- two
# replayers of one area, the thing the claim exists to prevent -- and the
# fix was to re-read the row afterwards and give the claim back if it had
# beaten since the fence. That also handed back a claim the re-attached
# node had NOT re-taken: an area claimed by a node with no replay of it
# running, waited on until the claim cap (F10). The claim now carries the
# claimant's incarnation (replay_incarnation, format 0x000A) and the swap
# compares it.
#
# Staged: this node's own area is DIRTY with a replay claim naming a
# departed row at incarnation 111; the mount's attach takes it over,
# held before its swap (reclaim_stall_before_swap_ms) while that row
# re-attaches (a beat and a new incarnation).
#
#  A. the row re-attaches and claims the area again (incarnation 222):
#     the claim stays its own and the mount waits on it; once released,
#     the mount completes.
#  B. the row re-attaches WITHOUT re-claiming: the mount takes the claim
#     over, replays, and completes -- nothing is handed back.
#
# DISCRIMINATION: with the swap comparing the row only and the hb_seq
# give-back (the code before 0x000A), B fails: the claim is given back
# to the row and the mount waits on it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms ] || { skip "reclaim_stall_before_swap_ms is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 rcsr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rcsr)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 4))
ct_umount "$MNT"

# plant: row $PEER departed at incarnation 111, holding a DIRTY claim on our area
plant() {
    "$NPOKE" "$DEV" "$PEER" 1 bb 0 >/dev/null 2>&1 || { fail "setup: could not register row $PEER"; ct_exit; }
    "$NPOKE" "$DEV" "$PEER" --inc 111 >/dev/null
    JOURNAL_POKE_INC=111 "$JPOKE" "$DEV" "$NID" --claim "$PEER" >/dev/null
    blockdev --flushbufs "$DEV"
    grep -q "replay_owner=$PEER .* incarnation=111 " <<<"$("$JPOKE" "$DEV" "$NID" --dump)" ||
        { fail "setup: the planted claim is not on the device"; ct_exit; }
}

# ------------------------------------------------------------------- A
log "A: the replayer re-attaches and claims the area again"
plant
ct_param_set reclaim_stall_before_swap_ms 2000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
sleep 0.8
( "$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1; "$NPOKE" "$DEV" "$PEER" --inc 222 >/dev/null 2>&1
  JOURNAL_POKE_INC=222 "$JPOKE" "$DEV" "$NID" --claim "$PEER" >/dev/null 2>&1
  # Keep the replayer live while we look.
  for _ in $(seq 1 8); do sleep 1; "$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1; done ) &
B=$!
sleep 4
D="$("$JPOKE" "$DEV" "$NID" --dump)"
MOUNTED=0
mountpoint -q "$MNT" && MOUNTED=1
log "A: 4.8 s in: mounted=$MOUNTED; $D"
dmesg_since "$MARK" | grep -q "revoked stale node $PEER" ||
    { kill "$B" 2>/dev/null; fail "A: setup: the attach never tried to take the claim over"; }
grep -q "replay_owner=$PEER .* incarnation=222 " <<<"$D" && [ "$MOUNTED" = 0 ] &&
    pass "A: the re-taken claim is still the replayer's, and the mount waits on it" ||
    fail "A: the claim of a replayer that re-attached and re-claimed was taken (mounted=$MOUNTED): $D"
kill "$B" 2>/dev/null || true; wait "$B" 2>/dev/null || true
"$JPOKE" "$DEV" "$NID" --claim release >/dev/null
ct_param_set reclaim_stall_before_swap_ms 0
RC=0
wait "$MPID" || RC=$?
[ "$RC" = 0 ] && pass "A: the mount completes once the replayer lets go" || fail "A: the mount failed (rc $RC)"
mountpoint -q "$MNT" && ct_umount "$MNT"

# ------------------------------------------------------------------- B
log "B: the replayer re-attaches without claiming the area again"
plant
ct_param_set reclaim_stall_before_swap_ms 2000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
sleep 0.8
( "$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1; "$NPOKE" "$DEV" "$PEER" --inc 333 >/dev/null 2>&1
  for _ in $(seq 1 8); do sleep 1; "$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1; done ) &
B=$!
RC=0
timeout 12 tail --pid="$MPID" -f /dev/null || true
MOUNTED=0
mountpoint -q "$MNT" && MOUNTED=1
D="$("$JPOKE" "$DEV" "$NID" --dump)"
kill "$B" 2>/dev/null || true; wait "$B" 2>/dev/null || true
ct_param_set reclaim_stall_before_swap_ms 0
dmesg_since "$MARK" | grep -q "revoked stale node $PEER" || fail "B: setup: the attach never tried to take the claim over"
[ "$MOUNTED" = 1 ] && pass "B: the mount took the dead incarnation's claim and came up" ||
    fail "B: the mount is still waiting on a claim the re-attached replayer never re-took: $D"
grep -q "replay_owner=$PEER " <<<"$D" && fail "B: the claim was handed back to row $PEER: $D" ||
    pass "B: row $PEER was not handed a claim no replay of its holds"
if [ "$MOUNTED" = 0 ]; then
    "$JPOKE" "$DEV" "$NID" --claim release >/dev/null
    wait "$MPID" || true
else
    wait "$MPID" || true
fi
mountpoint -q "$MNT" && ct_umount "$MNT"
"$NPOKE" "$DEV" "$PEER" 0 00 0 >/dev/null 2>&1 || true
ct_exit
