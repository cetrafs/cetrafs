#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim lands its saved row in the same compare-and-write as the claim, so a claim that loses writes nothing
#
# A repair claim that borrows a registered row keeps the row it displaced
# in its own block (CETRAFS_REPAIR_SAVED_OFF), so the release or a reap
# can put the registration back. The saved copy used to sit past the
# first sector and was written blind with WRITE(16) BEFORE the claim's
# compare-and-write. A claimant that lost the race had already written
# its copy over the winner's: the winner's saved row became whatever the
# loser had read, and the registration the winner borrowed was lost
# (L24). Since format 0x000A the copy lives inside the sector the swap
# covers, and a claim that miscompares writes nothing.
#
# Staged on an LIO disk (512-byte sectors, real CAW), every row taken by
# a node that left cleanly, so a repairer must borrow one: fsck -r reads
# row 0 and is held before its claim (CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS);
# meanwhile another repairer's claim lands on row 0, saving a DIFFERENT
# registration (hb_seq 77). The held fsck must lose, and row 0 must
# still carry that saved row.
#
# DISCRIMINATION: with the copy written outside the swap, the losing
# fsck's write replaces saved_hb 77 by the row it had read.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
RRP="$(ct_helper repair_reap_probe)"
NPOKE="$(ct_helper node_poke)"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 600 rcsaved)"
DISK="$(ct_lio_disks "$IMG" 1)" || { skip "no LIO loopback target here"; ct_exit; }
ct_mkfs "$DISK" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
[ "$(blockdev --getss "$DISK")" = 512 ] || log "(logical block $(blockdev --getss "$DISK"): the swap covers the whole row block)"

# Every row: a node that left cleanly (last_seen 0 plants departure CLEAN).
for r in 0 1 2 3; do "$NPOKE" "$DISK" "$r" 1 "$(printf 'b%d' "$r")" 0 >/dev/null; done
blockdev --flushbufs "$DISK"
grep -q 'departure=1 ' <<<"$("$NPOKE" "$DISK" 0)" || { fail "setup: row 0 is not a clean departure"; ct_exit; }

OUT="$(ct_tmp rcsaved-out)"
CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS=6 "$FSCK" -r "$DISK" >"$OUT" 2>&1 &
FP=$!
sleep 2
# Another repairer's claim lands on row 0 while fsck is held, borrowing a
# registration different from the one fsck read (saved hb_seq 77).
"$RRP" "$DISK" plant 0
S0="$("$RRP" "$DISK" show 0)"
grep -q "state=2 hb=5 saved=1 saved_ok=1 saved_hb=77" <<<"$S0" ||
    { fail "setup: the planted claim reads '$S0'"; kill "$FP" 2>/dev/null; wait "$FP" 2>/dev/null; ct_exit; }
pass "setup: row 0 is another repairer's claim, saving the row with hb_seq 77"
RC=0
wait "$FP" || RC=$?
grep -q "claimed registry row 0" "$OUT" &&
    { fail "setup: the held fsck claimed row 0 over the other claim: $(tail -2 "$OUT" | tr '\n' ' ')"; ct_exit; }
log "the held fsck exited $RC: $(grep -m1 -iE 'another|claim|ERR' "$OUT" || tail -1 "$OUT")"
S1="$("$RRP" "$DISK" show 0)"
grep -q "state=2 hb=5 " <<<"$S1" && pass "the other repairer still holds row 0" ||
    fail "row 0 is no longer the other repairer's claim: $S1"
grep -q "saved=1 saved_ok=1 saved_hb=77" <<<"$S1" && pass "and its saved row is the one it saved (hb_seq 77)" ||
    fail "the losing claim replaced the winner's saved row: $S1"
ct_exit
