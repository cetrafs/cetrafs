#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replayer that came back before its fence is "someone else's", not an error
#
# Taking over a dead node's journal replay from a stale replayer fences
# that replayer first. When it re-attached in between, the fence answers
# -EBUSY ("a live node after all"), and the replay claim handed that on.
# Its contract is 0 or -EEXIST ("someone else is handling it"): a caller
# about to build on the replay waits on -EEXIST, the heartbeat sweep
# leaves it to the next tick and counts the decline. -EBUSY instead
# failed the replay -- and with it a lock break, an open or a Zone Group
# claim waiting on that journal (N-16).
#
# Staged with one node: node 1 is dead with a dirty journal area whose
# replay claim node 2 holds; node 2 is dead too. The heartbeat's sweep
# fences node 1, then the replay claim fences node 2. fence_stall_ms is
# one-shot, so it is armed again after node 1's fence; node 2's row
# beats while the second one waits:
#   1. the fence sees node 2 come back, and the replay is declined as
#      someone else's (journal_replay_declines moves), not failed;
#   2. node 1's journal is left to node 2 (its claim stands).
#
# DISCRIMINATION: with the claim returning the fence's -EBUSY, the sweep
# logs the replay as failed (-16) and nothing counts a decline (check 1).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_stall_ms ] || { skip "fence_stall_ms is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters

IMG="$(ct_image 560 rcfr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rcfr)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"

set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 bb
poke_dead_peer "$DEV" 2 cc
"$JPOKE" "$DEV" 1 --claim 2 >/dev/null
blockdev --flushbufs "$DEV"
jstate() { "$JPOKE" "$IMG" 1 --dump | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }
DIRTY="$(jstate state)"
[ "$(jstate replay_owner)" = 2 ] || fail "setup: node 1's replay claim is not node 2's: $("$JPOKE" "$IMG" 1 --dump)"

MARK="$(dmesg_mark)"
ct_param_set fence_stall_ms 2000 # the sweep's fence of node 1; the mount gate's own fence is not held
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
D0="$(sed -n 's/^journal_replay_declines: //p' "$INFO")"
# First stall taken (node 1's fence): arm the second, for node 2's.
for _ in $(seq 1 200); do [ "$(cat $P/fence_stall_ms)" = 0 ] && break; sleep 0.05; done
echo 2000 >$P/fence_stall_ms
for _ in $(seq 1 100); do [ "$(cat $P/fence_stall_ms)" = 0 ] && break; sleep 0.05; done
[ "$(cat $P/fence_stall_ms)" = 0 ] || { echo 0 >$P/fence_stall_ms; fail "setup: no second fence was held"; }
# Node 2 re-attaches: no departure, and beating.
STOP="$IMG.stopbeat"; ct_track file "$STOP"
( while [ ! -e "$STOP" ]; do
    "$NPOKE" "$IMG" 2 --depart 0 >/dev/null 2>&1 || true
    "$NPOKE" "$IMG" 2 --beat >/dev/null 2>&1 || true
    sleep 0.2
done ) &
BEATER=$!
sleep 4
D1="$(sed -n 's/^journal_replay_declines: //p' "$INFO")"
dmesg_since "$MARK" | grep -q 'node 2 came back since it was judged stale -- not revoking, not reclaiming a journal replay claim' &&
    pass "setup: the replay claim's fence was held, and saw node 2 come back" ||
    fail "setup: no 'node 2 came back' from the replay claim: $(dmesg_since "$MARK" | grep 'fence:' | tail -2 | tr '\n' ' ')"
FAILED="$(dmesg_since "$MARK" | grep -c "replay of stale node 1's journal failed" || true)"
log "declines $D0 -> $D1, sweep failures logged: $FAILED"
[ "$FAILED" = 0 ] && [ "$D1" -gt "$D0" ] &&
    pass "1: the replay was declined as node 2's, not failed" ||
    fail "1: declines $D0 -> $D1, failures logged $FAILED: $(dmesg_since "$MARK" | grep -m1 'journal failed')"
[ "$(jstate replay_owner)" = 2 ] && [ "$(jstate state)" = "$DIRTY" ] &&
    pass "2: node 1's journal was left to node 2" || fail "2: node 1's area: $("$JPOKE" "$IMG" 1 --dump)"

touch "$STOP"
kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true
ct_umount "$MNT"
ct_exit
