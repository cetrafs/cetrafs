#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not retire a registry row a journal replay claim names
#
# On a full registry fsck -r retires departed rows nothing references
# (repair_claim_retire.sh). "Nothing" was Zone Groups, locks, presence
# bits and a row's own dirty journal -- not a replay claim, which names
# the REPLAYER's row on another node's area. A node that died mid-replay
# left its row departed and its claim on the area; once retired, the next
# node to register took that row and read, to the area's owner, as a
# live replayer mid-replay: the owner waited on a claim nobody releases.
#
# Setup: a two-row registry, both departed; row 0's journal is DIRTY and
# claimed by row 1 -- row 1's only reference.
#
# DISCRIMINATION: proven by dropping the replay_owner reference from
# fsck's retirement pass: row 1 is retired.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 560 rrrc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rrrc)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 2 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
ct_umount "$MNT"
[ "$NID" = 0 ] || { fail "setup: this node took row $NID, not 0"; ct_exit; }
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1 || { fail "setup: could not register row 1"; ct_exit; }
"$JPOKE" "$DEV" 0 --claim 1 >/dev/null
blockdev --flushbufs "$DEV"
grep -q "replay_owner=1 " <<<"$("$JPOKE" "$DEV" 0 --dump)" || { fail "setup: the replay claim is not on the device"; ct_exit; }
state() { "$NPOKE" "$IMG" "$1" | sed -n 's/^state=\([0-9]*\) .*/\1/p'; }
[ "$(state 0)" = 1 ] && [ "$(state 1)" = 1 ] || { fail "setup: not two registered rows ($(state 0)/$(state 1))"; ct_exit; }

OUT="$("$FSCK" -r "$DEV" 2>&1 || true)"
log "$(grep -E 'claimed registry row|retired|registry' <<<"$OUT" | tr '\n' ';')"
ROW="$(sed -n 's/^  claimed registry row \([0-9]*\) .*/\1/p' <<<"$OUT")"
[ "$ROW" = 0 ] || { fail "setup: fsck -r borrowed row '$ROW', not 0 -- row 1 was never a candidate"; ct_exit; }
grep -q "retired node slot 1" <<<"$OUT" &&
    fail "fsck -r retired row 1, which a replay claim on node 0's journal still names" ||
    pass "fsck -r kept row 1: a replay claim names it"
[ "$(state 1)" = 1 ] && pass "row 1 is still registered" || fail "row 1 is in state $(state 1)"
grep -q "replay_owner=1 " <<<"$("$JPOKE" "$DEV" 0 --dump)" && pass "and the claim still names it" ||
    fail "the claim changed: $("$JPOKE" "$DEV" 0 --dump)"
ct_exit
