#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# taking a dead node's lock waits for a live peer replaying its journal
#
# Before any node takes a dead node's namespace lock, file lock or Zone
# Group, it replays that node's journal: the dead node may have been
# mid-operation under exactly that claim. Replay is serialized by a
# replay claim on the dead node's journal area. A node that found the
# claim held by a LIVE peer used to be told "fine, the peer is on it"
# (cetrafs_journal_replay_node() returned 0) -- and then stole the lock
# and wrote the blocks that peer was still judging, entry by entry. The
# replayer then refuses an entry as changed (a half-done rename stays
# half done) or, having judged it already, writes the dead node's old
# image over the new one. Only the heartbeat sweep, which takes
# nothing, may walk away; everything else now waits.
#
# Staged with one node: node 1 is dead, holds the namespace lock on a
# directory, and has a dirty journal area whose replay claim node 2
# holds; force_live_replay_claim makes that claim read as live (a
# genuinely live replayer cannot be made single-node -- see
# journal_attach_wait.sh). A create in the directory must wait, the
# lock must still be node 1's, and the create must complete once the
# claim is released.
#
# DISCRIMINATION: with nslock.c passing wait_for_claim=false again, the
# create completes at once and node 1's lock is already gone.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 jsteal)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jsteal)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
DINO="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"

# Node 1: dead, holding d's namespace lock, journal dirty, its replay
# claimed by node 2.
"$LPOKE" "$DEV" "$DINO" --ns 1 >/dev/null
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 bb
"$JPOKE" "$DEV" 1 --claim 2 >/dev/null
blockdev --flushbufs "$DEV"
ct_param_set force_live_replay_claim 1

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
wait_out_stale_window

touch "$MNT/d/created" &
TPID=$!
sleep 3
if kill -0 "$TPID" 2>/dev/null; then
    pass "3s in, the create is still waiting out the live replay of the dead holder's journal"
else
    wait "$TPID" && fail "the create COMPLETED while a live peer was still replaying the dead holder's journal" ||
        fail "the create failed instead of waiting (exit=$?)"
fi
OWNER="$("$LPOKE" "$DEV" "$DINO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')"
[ "$OWNER" = 1 ] && pass "and the dead node's namespace lock was not taken meanwhile" ||
    fail "the namespace lock moved to node $OWNER while the dead holder's journal was still being replayed"

# The "peer" finishes: claim released, area parked clean.
"$JPOKE" "$DEV" 1 --claim release >/dev/null
blockdev --flushbufs "$DEV"
DEADLINE=$((SECONDS + 30))
while kill -0 "$TPID" 2>/dev/null && [ "$SECONDS" -lt "$DEADLINE" ]; do sleep 0.5; done
if kill -0 "$TPID" 2>/dev/null; then
    fail "the create did not complete within 30s of the claim being released"
    kill "$TPID" 2>/dev/null || true
elif wait "$TPID"; then
    [ -e "$MNT/d/created" ] && pass "the create completed once the replay was done" ||
        fail "the create returned 0 but left no file"
else
    fail "the create failed after the claim was released (exit=$?)"
fi
ct_param_set force_live_replay_claim 0

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
