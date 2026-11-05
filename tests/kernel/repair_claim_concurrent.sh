#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two repairers that start together never both repair; nor one on a superblock that moved
#
# fsck -r and growfs claim the volume with a BLIND write of a registry
# row (the tools have no COMPARE AND WRITE). Two started together could
# each find no claim, each write one -- into the same free row, the
# later write winning, or into two -- and both repair the volume at
# once. And the superblock they act on was read before the claim, so a
# change landing in between was under the claim but not in their copy
# (audit L34).
#
# A claim now carries a nonce and settles before it is trusted: a row
# that no longer carries ours was taken by the other repairer; a second
# REPAIR row is a concurrent claimant, and whoever sees one yields; and
# the superblock is read again under the claim.
#
# Staged with CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS, a pause between a
# tool's "is anyone repairing?" check and its claim, so two tools both
# pass the check.
#   A. same row: both scan before either writes.
#   B. two rows: the second scans after the first's claim landed.
#   C. the superblock changes between the read and the claim.
#
# DISCRIMINATION: the previous tools run both repairs in A and B to the
# end, and C's repair runs on the old superblock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
SB_POKE="$(ct_helper sb_poke)"
NPOKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 repconc)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
O1="$(ct_tmp repconc-1)"; O2="$(ct_tmp repconc-2)"

# pair <delay1> <delay2>: two fsck -r, prints "<completed> <yielded>"
pair() {
    CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS="$1" "$FSCK" -r "$DEV" >"$O1" 2>&1 &
    local p1=$!
    CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS="$2" "$FSCK" -r "$DEV" >"$O2" 2>&1 &
    local p2=$!
    wait "$p1" || true
    wait "$p2" || true
    local done=0 yielded=0 o
    for o in "$O1" "$O2"; do
        if grep -q "another repair claimed this volume at the same time" "$o"; then
            yielded=$((yielded + 1))
        elif grep -q "claimed registry row" "$o"; then
            done=$((done + 1))
        fi
    done
    echo "$done $yielded"
}
no_repair_rows() {
    local r
    for r in 0 1 2 3; do
        "$NPOKE" "$DEV" "$r" | grep -q "^state=2 " && return 1
    done
    return 0
}

read -r D Y <<<"$(pair 2 2)"
log "A (same row): $D repaired, $Y yielded"
[ "$D" = 1 ] && [ "$Y" = 1 ] && pass "A: of two repairers that claimed the same row, exactly one repaired" ||
    fail "A: $D repaired and $Y yielded -- $(tail -1 "$O1") / $(tail -1 "$O2")"
no_repair_rows && pass "A: and no claim was left behind" || fail "A: a repair claim was left in the registry"

read -r D Y <<<"$(pair 2 3)"
log "B (two rows): $D repaired, $Y yielded"
[ "$D" -le 1 ] && [ $((D + Y)) = 2 ] && pass "B: of two repairers holding two rows, at most one repaired ($D)" ||
    fail "B: $D repaired and $Y yielded -- $(tail -1 "$O1") / $(tail -1 "$O2")"
no_repair_rows && pass "B: and no claim was left behind" || fail "B: a repair claim was left in the registry"

# C: the superblock moves on while the repair is between its read and
# its claim, as a grow finishing would leave it.
LG="$("$SB_POKE" "$DEV" | sed -n "s/^layout_gen=//p")"
CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS=3 "$FSCK" -r "$DEV" >"$O1" 2>&1 &
P=$!
sleep 1
"$SB_POKE" "$DEV" layout_gen $((${LG:-0} + 1)) >/dev/null
wait "$P" || true
grep -q "the superblock changed while this repair claimed the volume" "$O1" &&
    pass "C: a repair whose superblock changed before its claim stopped" ||
    fail "C: the repair went on with a superblock read before its claim: $(tail -2 "$O1")"
"$SB_POKE" "$DEV" layout_gen "${LG:-0}" >/dev/null
no_repair_rows && pass "C: and gave its claim back" || fail "C: a repair claim was left in the registry"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
