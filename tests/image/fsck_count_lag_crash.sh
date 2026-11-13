#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a crashed owner's free-count lag is a note; a clean owner's is an error
#
# Free counts accrue in memory and reach their descriptors only at
# durability boundaries, so a node that crashes leaves the on-disk counts
# of the Zone Groups it owned behind their bitmaps. The next owner
# recounts them when it claims the Zone Group, and the node itself does
# at re-attach (cetrafs_zg_reconcile_free_counts()); a count never
# decides which block is free. fsck run on the crashed image reported
# the lag as ERR, which told an operator to stop every VM for an
# `fsck -r` the next mount makes unnecessary (found by the live-grow crash
# rig, tests/crash/growfs_live_crash.sh).
#
# fsck now notes the lag when the Zone Group's owner row did not depart
# cleanly (cetrafs_count_lag_expected()), and keeps it an error when the
# owner departed cleanly -- its counts were flushed, so a mismatch is an
# accounting bug -- and for unowned groups (image/fsck_count_convergence.sh).
#
# 1: row 0 registered, never departed, owns Zone Group 0; Block Group 0's
#    count and the Zone Group's aggregate both drifted. fsck exits 0 and
#    notes both; fsck -r still recounts them; a second fsck notes nothing.
# 2: the same drift with row 0 departed cleanly: ERR, exit nonzero.
#
# DISCRIMINATION: case 1 is the change (fsck.c before it: ERR, exit 1);
# case 2 is the control that the note did not swallow the real error.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"
NPOKE="$(ct_helper node_poke)"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 560 countlag)"
DEV="$(ct_loop "$IMG")"

bg_free() { "$BG_POKE" "$DEV" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9][0-9]*\).*/\1/p'; }

# <tag> <departure: 0 none, 1 clean>
stage() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$NPOKE" "$DEV" 0 1 a0 "$(date +%s)" >/dev/null
    [ "$2" = 1 ] && "$NPOKE" "$DEV" 0 --depart 1 >/dev/null
    "$ZG_POKE" "$DEV" 0 0 >/dev/null
    BASE="$(bg_free)"
    [ -n "$BASE" ] || { fail "$1 setup: no BG0 count"; ct_exit; }
    ct_fsck "$DEV" >/dev/null 2>&1 || { fail "$1 setup: the staged volume is not clean before the drift: $(ct_fsck "$DEV" 2>&1 | grep -m2 ERR)"; ct_exit; }
    "$BG_POKE" "$DEV" 0 $((BASE - 64)) >/dev/null
    "$ZG_POKE" "$DEV" 0 free $((BASE + 64)) >/dev/null
    blockdev --flushbufs "$DEV"
}

log "1: Zone Group 0's owner crashed (row 0 never departed)"
stage crashed 0
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
grep -q "did not depart cleanly (hb_seq" <<<"$OUT" || { fail "1 setup: fsck does not see row 0 as left behind: $(grep -m1 'node slot 0' <<<"$OUT")"; ct_exit; }
[ "$rc" = 0 ] && pass "1: fsck exits 0 on a crashed owner's count lag" ||
    fail "1: fsck exit $rc: $(grep -m3 ERR <<<"$OUT" | tr '\n' ' ')"
grep -q "note: BG0 cached free_data_blocks" <<<"$OUT" && pass "1: the Block Group's lag is named as a note" ||
    fail "1: no note for BG0"
grep -q "note: ZG0 aggregate free_data_blocks" <<<"$OUT" && pass "1: the Zone Group aggregate's lag is named as a note" ||
    fail "1: no note for the ZG0 aggregate"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
OUT="$(ct_fsck "$DEV" 2>&1)" || true
[ "$(bg_free)" = "$BASE" ] && ! grep -q "note: .*free_data_blocks" <<<"$OUT" &&
    pass "1: fsck -r still recounts both, and a second fsck notes nothing" ||
    fail "1: after -r BG0 reads $(bg_free) (want $BASE): $(grep -m2 'free_data_blocks' <<<"$OUT" | tr '\n' ' ')"

log "2: the same lag with the owner departed cleanly"
stage clean 1
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "ERR: BG0 cached free_data_blocks" <<<"$OUT" && grep -q "ERR: ZG0 aggregate" <<<"$OUT" &&
    pass "2: a clean owner's lag stays ERR (exit $rc)" ||
    fail "2: exit $rc: $(grep -m3 -E 'ERR|note' <<<"$OUT" | tr '\n' ' ')"
ct_exit
