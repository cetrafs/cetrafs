#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay claim on a dead peer's journal that is not released is retried
#
# Replaying a stale peer's journal claims its flag block (replay_owner =
# this node) and releases it parking the flag CLEAN, in one CAS. A
# release that failed was logged and left "for the next trigger" -- but
# the trigger is the dead-peer sweep, which re-enters only while that
# peer is STALE. A peer that came back in between found our claim live,
# waited it out and failed its mount, and beating again was never swept:
# it could not mount for as long as this node lived.
#
# Staged: a stale peer row with a dirty journal entry; the heartbeat's
# sweep replays it with its release failing once (journal_release_fail_
# once); the peer starts beating at once. The claim must still be
# released.
#
# DISCRIMINATION: without the heartbeat retry the flag still reads
# replay_owner=<this node> when the wait ends.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_release_fail_once ] || { skip "journal_release_fail_once is missing"; ct_exit; }
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 jrel)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrel)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 4))

ct_param_set journal_release_fail_once 1
PAY="$(ct_tmp jrel-pay)"; head -c 4096 /dev/zero >"$PAY"
MARK="$(dmesg_mark)"
"$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1   # REGISTERED, last_seen=0: stale at once
"$JPOKE" "$IMG" "$PEER" 0 60001 "$PAY" >/dev/null 2>&1
for _ in $(seq 1 150); do
    dmesg_since "$MARK" | grep -q "failed to release the replay claim.*node $PEER" && break
    sleep 0.2
done
# The peer comes back: beating, it is no longer swept.
( while :; do "$NODEPOKE" "$IMG" "$PEER" --beat >/dev/null 2>&1 || true; sleep 0.5; done ) &
BEATER=$!
ct_track cmd "kill $BEATER"
dmesg_since "$MARK" | grep -q "failed to release the replay claim.*node $PEER" ||
    { fail "setup: the sweep's release never failed ($(dmesg_since "$MARK" | grep -i journal | tail -2))"; ct_exit; }
pass "setup: the sweep replayed node $PEER and its release failed"

OWNER=""
for _ in $(seq 1 20); do
    D="$("$JPOKE" "$IMG" "$PEER" --dump)"
    OWNER="$(sed -n 's/.*replay_owner=\([0-9]*\).*/\1/p' <<<"$D")"
    [ "$OWNER" != "$NID" ] && break
    sleep 1
done
log "node $PEER's flag: $D"
[ "$OWNER" != "$NID" ] && pass "the claim was released ($D)" ||
    fail "node $PEER's journal is still claimed by this node 20 s on ($D) -- that node cannot mount"
kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true
ct_umount "$MNT"
ct_exit
