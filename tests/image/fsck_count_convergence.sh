#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r converges on free-count drift -- including the legal crash state
#
# The kernel flushes a BG's free count and its ZG's aggregate as two
# separate compare-and-swaps, so a crash between them leaves the two caches
# disagreeing on a perfectly healthy volume. fsck used to compare exactly
# those two caches in a STRUCTURAL check and return fatally on mismatch --
# before the content pass that (a) detects the drift against the bitmaps,
# the actual truth, and (b) repairs both counts from them under -r. A
# crashed-but-healthy volume was declared unrepairable, and every deeper
# detection (cross-file overlap above all) hid behind a count hiccup.
#
# That structural check is gone; this suite pins the behavior
# that replaces it: drifted counts are DETECTED by the content pass (plain
# fsck exits nonzero and names the bitmap-truth mismatch), REPAIRED by -r,
# and a second plain fsck is clean -- convergence, which the old fatal
# check made impossible (re-adding it fails the "reaches the content pass"
# and "clean after repair" assertions below).
#
# No kernel module and nothing mounted: mkfs writes the structures, the
# poke drifts one count, fsck must detect, repair, and converge.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 countconv)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

BASE="$("$BG_POKE" "$DEV" 0 --dump | grep -oP 'free_data_blocks=\K[0-9]+')"

log "the crash state: BG count moved, ZG aggregate not (two caches disagree)"
# Drift the BG count only (no sync-zg): BG != bitmap AND BG-sum != ZG --
# exactly what a crash between the two CAS flushes leaves behind.
"$BG_POKE" "$DEV" 0 $((BASE - 64)) >/dev/null
blockdev --flushbufs "$DEV"

OUT="$(ct_fsck "$DEV" 2>&1)" && fail "fsck exit 0 on drifted counts" || true
echo "$OUT" | grep -q "actually free in its bitmap" &&
    pass "plain fsck reaches the content pass and names the BG-vs-bitmap drift" ||
    fail "the content pass never ran -- a structural check bailed first:
$OUT"

log "repairing, then converging"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck -r repaired the drift from the bitmaps and a second run is CLEAN"
else
    fail "no convergence -- fsck still unhappy after -r: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -3)"
fi
[ "$("$BG_POKE" "$DEV" 0 --dump | grep -oP 'free_data_blocks=\K[0-9]+')" = "$BASE" ] &&
    pass "the repaired count equals the bitmap truth it was derived from" ||
    fail "repair wrote $("$BG_POKE" "$DEV" 0 --dump), expected free_data_blocks=$BASE"

ct_exit
