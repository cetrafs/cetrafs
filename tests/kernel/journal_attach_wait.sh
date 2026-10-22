#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Journal attach: a live peer replaying OUR OWN area blocks the mount until done
#
# When a peer declares this node dead it replays this node's journal area
# under a CAS replay claim. If this node remounts while that replay is still
# in flight, "whoever holds the claim finishes the job" -- the right answer
# for a THIRD node's area -- used to make the attach walk away and let the
# mount proceed: new entries written into slots whose headers the replayer's
# consume pass was about to zero (destroying their write-ahead protection),
# and new data written over blocks it was about to blindly rewrite with our
# old images. The attach now WAITS for a live claim on our own area to clear
# (or steals it the moment its holder goes stale), bounded so a wedged claim
# fails the mount loudly instead of hanging it.
#
# A genuinely live foreign replayer cannot be fabricated single-node (a
# poked registry row never heartbeats, and the no-CAW mount gate fences it
# before the attach even runs), so the force_live_replay_claim knob makes
# the claim read as live-held (restored at ct_exit). The discriminating
# assertion is the wait itself: with the fix the mount is still blocked
# seconds in and completes the moment the claim is released; without it the
# mount returns immediately -- failing the "still waiting" assertion.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_image 560 jwait)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jwait)"
# ct_mkfs_small formats with -J 0 (no journal); this suite needs one.
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

log "a live foreign replay claim on our own area: the mount must WAIT, not proceed"
# The first mount will register as node 0; plant a foreign (node 1) replay
# claim on node 0's journal area, held "live" via the knob.
"$JPOKE" "$DEV" 0 --claim 1 >/dev/null
blockdev --flushbufs "$DEV"
ct_param_set force_live_replay_claim 1

mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
sleep 3
if kill -0 "$MPID" 2>/dev/null && ! mountpoint -q "$MNT"; then
    pass "3s in, the mount is still waiting out the live replay claim"
else
    # Either it finished early (the attach walked away from a live claim on
    # its own area -- the bug) or it died outright (setup problem; the wait
    # below reports its exit code).
    wait "$MPID" && fail "the mount COMPLETED while a live peer held our area's replay claim" ||
        fail "the mount errored instead of waiting (exit=$?)"
fi

# The "peer" finishes its replay: claim released, flag parked clean. The
# waiter must notice and complete the mount.
"$JPOKE" "$DEV" 0 --claim release >/dev/null
blockdev --flushbufs "$DEV"
if wait "$MPID"; then
    require_cetrafs_mount "$MNT"
    pass "the mount completed as soon as the claim was released"
else
    fail "the mount failed after the claim was released (exit=$?)"
fi
ct_param_set force_live_replay_claim 0
: >"$MNT/proof"
[ -e "$MNT/proof" ] && pass "and the volume is writable" || fail "mounted but not writable"
ct_umount "$MNT"

log "control: a claim whose holder is NOT live is stolen, no waiting"
# Same planted claim, knob off: node 1's row does not exist, so the holder
# reads stale and the attach's ordinary steal path takes the claim and
# replays immediately -- the wait must not over-wait.
"$JPOKE" "$DEV" 0 --claim 1 >/dev/null
blockdev --flushbufs "$DEV"
START=$(date +%s)
mount -t cetrafs "$DEV" "$MNT"
TOOK=$(( $(date +%s) - START ))
require_cetrafs_mount "$MNT"
[ "$TOOK" -le 10 ] && pass "a dead holder's claim is stolen at attach without waiting (took ${TOOK}s)" ||
    fail "the mount waited ${TOOK}s on a claim whose holder is not even registered"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
DUMP="$("$JPOKE" "$DEV" 0 --dump)"
grep -q "^state=0 " <<<"$DUMP" && pass "the stolen area was replayed and parked clean ($DUMP)" ||
    fail "area not parked clean after the steal: $DUMP"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
