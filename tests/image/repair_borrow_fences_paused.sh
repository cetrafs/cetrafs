#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a registration a repair borrowed from a node that did not depart comes back fenced
#
# With no FREE row left, fsck -r and growfs borrow a registered row: a
# CLEAN departure first, else one whose beat stood still for the probe.
# The second kind may be a node that is PAUSED, not dead. While the
# claim holds its row a peer can take that node's Zone Groups, and a
# fence of a REPAIR row bumps nothing; the release then put the
# registration back exactly as it was, old fence_epoch and all, and the
# node, resumed, passed its epoch check and kept writing into what it no
# longer owned (audit 2026-11-22 N-56). What comes back now carries the
# fence: fence_epoch + 1, the reason RECLAIM, and a valid checksum.
#
# Every row of a two-row registry is REGISTERED with a stale beat and
# departure NONE, so fsck -r must probe and borrow one:
#   1. setup: it says it claimed a row, and released it (state back to 1);
#   2. that row's fence_epoch moved by one, its reason is RECLAIM, and
#      the rest of the registration -- uuid, incarnation -- is as it was;
#   3. the row's checksum verifies (a read-only fsck does not report it).
# A CLEAN departure keeps coming back byte for byte
# (kernel/repair_claim_blocks_mount.sh).
#
# DISCRIMINATION (measured on the unfixed code): check 2 fails, the epoch
# unchanged.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 rbfp)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 2 -N 1024 -f >/dev/null
ROWS="$("$SBPOKE" "$IMG" | sed -n 's/^node_table_count[^0-9]*\([0-9]*\).*/\1/p' | head -1)"
[ -n "$ROWS" ] && [ "$ROWS" -ge 1 ] || { fail "setup: cannot read node_table_count"; ct_exit; }
OLD=$(($(date +%s) - 3600))
for r in $(seq 0 $((ROWS - 1))); do
    "$NPOKE" "$IMG" "$r" 1 "c$r" "$OLD" >/dev/null
    "$NPOKE" "$IMG" "$r" --depart 0 >/dev/null
done
blockdev --flushbufs "$DEV"
field() { sed -n "s/.*[ ^]$2=\([0-9a-fx]*\).*/\1/p" <<<" $("$NPOKE" "$IMG" "$1")" | head -1; }
declare -A EP INC
for r in $(seq 0 $((ROWS - 1))); do EP[$r]="$(field "$r" fence_epoch)" INC[$r]="$(field "$r" incarnation)"; done

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
B="$(sed -n 's/^  claimed registry row \([0-9]*\) .*/\1/p' <<<"$OUT" | head -1)"
if [ -z "$B" ]; then
    fail "1: setup: fsck -r claimed no row: $(grep -i registry <<<"$OUT" | head -2 | tr '\n' ' ')"
    ct_exit
fi
[ "$(field "$B" state)" = 1 ] && pass "1: setup: fsck -r borrowed row $B and put a registration back" ||
    { fail "1: setup: row $B is in state $(field "$B" state) after the repair"; ct_exit; }

E1="$(field "$B" fence_epoch)"
if [ "$E1" = $((${EP[$B]} + 1)) ] && [ "$(field "$B" fence_reason)" = 1 ] && [ "$(field "$B" incarnation)" = "${INC[$B]}" ]; then
    pass "2: row $B came back fenced: fence_epoch ${EP[$B]} -> $E1, reason RECLAIM, same incarnation"
else
    fail "2: row $B: fence_epoch ${EP[$B]} -> $E1, reason $(field "$B" fence_reason), incarnation ${INC[$B]} -> $(field "$B" incarnation)"
fi
FO="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "node slot $B fails its checksum" <<<"$FO" && fail "3: fsck: row $B fails its checksum" ||
    pass "3: row $B's checksum verifies (fsck does not report it)"
ct_exit
