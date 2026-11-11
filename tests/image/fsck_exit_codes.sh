#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's exit status says what it did: 3 when it could not examine, 1 when the volume cannot be used
#
# Three cases where the status lied (audit 2026-11-11):
#  F1 a volume another node has mounted was refused with exit 1,
#     "problems found", about a volume nobody walked; it is 3.
#  F6 the live-peer probe ran once, before a walk that can take
#     minutes; a node mounting meanwhile was never noticed and the walk
#     over a changing volume ended in a verdict. Without -r (whose claim
#     keeps mounts out) fsck asks again before giving one.
#  F8 a Node Registry with no free row -- no new node can ever register
#     -- was a WARN, and the run ended "OK", exit 0.
#
#  1. a heartbeating peer: exit 3.
#  2. a peer that starts beating during the walk: exit 3, naming it.
#  3. a full registry of departed rows: exit 1; fsck -r retires them;
#     then exit 0.
#
# DISCRIMINATION (2026-11-11, fsck.c before this fix): 1 exits 1; 2
# ends "OK", exit 0; 3 ends "OK", exit 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 560 fsckrc)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -M 2 -f >/dev/null
SB="$IMG.sb"; ct_track file "$SB"
dd if="$DEV" of="$SB" bs=4096 count=1 status=none
"$FSCK" "$DEV" >/dev/null 2>&1 || { fail "setup: the fresh volume is not clean"; ct_exit; }
# A peer heartbeating for $2 seconds after a delay of $1.
beat() { bash -c 'sleep "$1"; for _ in $(seq 1 "$2"); do NODE_POKE_SB="$3" "$4" "$5" 1 --beat >/dev/null 2>&1 || true; sleep 1; done' _ "$1" "$2" "$SB" "$NPOKE" "$DEV" & }

log "1: a heartbeating peer on row 1"
"$NPOKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null
beat 0 8; B=$!
rc=0; OUT="$("$FSCK" "$DEV" 2>&1)" || rc=$?
wait "$B" 2>/dev/null || true
grep -q "is mounted by another node" <<<"$OUT" || { fail "1 setup: fsck did not see the peer: $(tail -1 <<<"$OUT")"; ct_exit; }
[ "$rc" = 3 ] && pass "1: refused, exit 3 (not examined)" || fail "1: refused with exit $rc"
"$NPOKE" "$DEV" 1 0 00 0 >/dev/null

log "2: a peer that mounts during the walk"
B=""
( sleep 1; "$NPOKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null ) &
P=$!
beat 2 14; B=$!
rc=0; OUT="$(CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=6 "$FSCK" "$DEV" 2>&1)" || rc=$?
wait "$P" "$B" 2>/dev/null || true
grep -q "holding before the block group pass" <<<"$OUT" && ! grep -q "is mounted by another node (" <<<"$OUT" ||
    { fail "2 setup: the walk did not start with the volume free: $(grep -m2 -E 'ERR|hold' <<<"$OUT")"; ct_exit; }
[ "$rc" = 3 ] && grep -q "a node mounted it while fsck walked it" <<<"$OUT" && pass "2: no verdict, exit 3" ||
    fail "2: exit $rc: $(tail -1 <<<"$OUT")"
# The re-check can wait a probe window of its own: it says so (review E3).
grep -q "walk done; checking again that no node mounted" <<<"$OUT" &&
    pass "2: the second probe is announced, not a silent pause" || fail "2: the re-check ran unannounced"
"$NPOKE" "$DEV" 1 0 00 0 >/dev/null

log "3: both rows registered and departed cleanly"
for r in 0 1; do
    "$NPOKE" "$DEV" $r 1 "a$r" "$(date +%s)" >/dev/null
    "$NPOKE" "$DEV" $r --depart 1 >/dev/null
done
grep -q "departure=1" <<<"$("$NPOKE" "$DEV" 1)" || { fail "3 setup: row 1 is not departed: $("$NPOKE" "$DEV" 1)"; ct_exit; }
rc=0; OUT="$("$FSCK" "$DEV" 2>&1)" || rc=$?
[ "$rc" = 1 ] && grep -q "Node Registry is full" <<<"$OUT" && pass "3: a full registry is a problem, exit 1" ||
    fail "3: exit $rc: $(grep -m1 -E 'Registry|OK' <<<"$OUT")"
OUT="$("$FSCK" -r "$DEV" 2>&1)" || true
grep -q "registry full: retired node slot" <<<"$OUT" || { fail "3 setup: fsck -r retired nothing: $(tail -2 <<<"$OUT")"; ct_exit; }
"$FSCK" "$DEV" >/dev/null 2>&1 && pass "3: after fsck -r retires the rows, exit 0" || fail "3: still not clean after -r"
losetup -d "$DEV"
ct_exit
