#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# taking over a stale replayer's claim gives it back if the replayer re-attached
#
# A journal area's replay claim names the replaying node's row. A node
# that finds the claim held by a stale row fences that row and swaps the
# claim to itself -- comparing the row NUMBER only. A replayer that
# re-attached in between, and still holds or took the claim again, wrote
# the very bytes the swap compares: two replayers of one area, the thing
# the claim exists to prevent. The lock, reader-bit and namespace-lock
# steals each re-read the holder's row after their swap
# (reclaim_vs_reattach.sh); the replay claim did not. Now it does, and
# gives the claim back.
#
# Staged: this node's own area is DIRTY with a replay claim naming a
# departed row; the mount's attach takes it over, held between fence and
# swap (reclaim_stall_before_swap_ms) while that row beats. The claim
# must still name the row afterwards, while the mount waits on it; the
# suite then releases it so the mount completes.
#
# DISCRIMINATION: proven by removing the re-attach check from
# cetrafs_journal_claim_replay(): the mount takes the claim and replays.
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

"$NPOKE" "$DEV" "$PEER" 1 bb 0 >/dev/null 2>&1 || { fail "setup: could not register row $PEER"; ct_exit; }
"$JPOKE" "$DEV" "$NID" --claim "$PEER" >/dev/null
blockdev --flushbufs "$DEV"
grep -q "replay_owner=$PEER " <<<"$("$JPOKE" "$DEV" "$NID" --dump)" ||
    { fail "setup: the planted claim is not on the device"; ct_exit; }

ct_param_set reclaim_stall_before_swap_ms 2000
mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
sleep 0.8
"$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1
# Keep the replayer live while we look.
( for _ in $(seq 1 8); do sleep 1; "$NPOKE" "$DEV" "$PEER" --beat >/dev/null 2>&1; done ) &
B=$!
sleep 4
D="$("$JPOKE" "$DEV" "$NID" --dump)"
MOUNTED=0
mountpoint -q "$MNT" && MOUNTED=1
log "4.8 s in: mounted=$MOUNTED; $D"
dmesg | tail -40 | grep -q "revoked stale node $PEER" ||
    { kill "$B" 2>/dev/null; fail "setup: the attach never tried to take the claim over"; }
grep -q "replay_owner=$PEER " <<<"$D" && [ "$MOUNTED" = 0 ] &&
    pass "the claim is the re-attached replayer's again, and the mount waits on it" ||
    fail "the claim of a replayer that re-attached was taken (mounted=$MOUNTED): $D"
dmesg | tail -40 | grep -q "came back while its replay claim was being taken" &&
    pass "and the give-back was logged" || fail "no give-back message in dmesg"

kill "$B" 2>/dev/null; wait "$B" 2>/dev/null || true
"$JPOKE" "$DEV" "$NID" --claim release >/dev/null
ct_param_set reclaim_stall_before_swap_ms 0
RC=0
wait "$MPID" || RC=$?
[ "$RC" = 0 ] && pass "the mount completes once the replayer lets go" || fail "the mount failed (rc $RC)"
mountpoint -q "$MNT" && ct_umount "$MNT"
"$NPOKE" "$DEV" "$PEER" 0 00 0 >/dev/null 2>&1 || true
ct_exit
