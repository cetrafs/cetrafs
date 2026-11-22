#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r never stamps a fresh checksum over a group record it did not verify
#
# fsck -r edits Block Group descriptors and Zone Group hot sectors for
# their counts -- a block it allocates, leaked blocks it clears and
# credits, the recount -- and stamps a fresh checksum over each. None of
# those edits verified the record it read: a sector damaged where the
# record pass did not see it came out of the run CRC-valid, damage and
# all, read as sound by every node after -- the opposite of the kernel's
# policy of leaving a record that fails its checksum for the run that
# rebuilds it (audit 2026-11-22, N-45). Now a record that does not verify
# is not edited, and fsck says so.
#
# Reaching it: the record pass rebuilds a damaged record, or blocks the
# whole repair (a Zone Group's rebuild waits only while a journal entry
# is unreplayed, and that blocks every edit too), so damage the edits can
# meet is damage that arrives after that pass. The suite puts it there:
# fsck -r holds before the block group pass
# (CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS) and ZG1's hot sector is
# damaged meanwhile; a leaked block in BG1, a member of ZG1, gives the
# repair a credit and a recount to write into it. After fsck -r:
#   1. a read-only fsck still finds ZG1's hot sector failing its CRC;
#   2. fsck -r said it left ZG1 alone.
#
# DISCRIMINATION: the control, in-suite -- CETRAFS_FSCK_RESTAMP_UNVERIFIED=1,
# the old edits: the damaged sector comes out valid.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
LEAK="$(ct_helper data_leak_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 frsv)"
DEV="$(ct_loop "$IMG")"
OUTF="$(ct_tmp frsv-out)"

# round <unverified 0|1> -> OUT (the repair's output), AFTER (read-only fsck)
round() {
    local pid i
    ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$LEAK" "$IMG" 1 100 1 >/dev/null
    blockdev --flushbufs "$DEV"
    : >"$OUTF" # the wait below must see THIS run's hold, not the last one's
    if [ "$1" = 1 ]; then
        CETRAFS_FSCK_RESTAMP_UNVERIFIED=1 CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=4 "$FSCK" -r "$DEV" >"$OUTF" 2>&1 &
    else
        CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=4 "$FSCK" -r "$DEV" >"$OUTF" 2>&1 &
    fi
    pid=$!
    for i in $(seq 1 60); do grep -q 'holding before the block group pass' "$OUTF" && break; sleep 0.25; done
    "$POKE" "$IMG" zg-hot 1 >/dev/null
    MID="$("$FSCK" "$DEV" 2>&1 | grep -c 'ERR: ZG1 hot-sector CRC mismatch' || true)"
    wait "$pid" || true
    OUT="$(cat "$OUTF")"
    blockdev --flushbufs "$DEV"
    AFTER="$("$FSCK" "$DEV" 2>&1 || true)"
}

round 1
grep -q 'holding before the block group pass' <<<"$OUT" && grep -q 'leaked' <<<"$OUT" && [ "$MID" = 1 ] ||
    { fail "control setup: fsck -r did not hold, or found no leak: $(grep -E 'hold|leak|ERR' <<<"$OUT" | head -3 | tr '\n' ' ')"; ct_exit; }
! grep -q "ERR: ZG1 hot-sector CRC mismatch" <<<"$AFTER" &&
    pass "control: edited unverified, ZG1's damaged hot sector came out CRC-valid" ||
    fail "control: the hazard did not reproduce (nothing restamped ZG1) -- the check cannot tell"
round 0
grep -q 'holding before the block group pass' <<<"$OUT" && [ "$MID" = 1 ] ||
    { fail "setup: fsck -r did not hold, or ZG1 was not damaged during the hold"; ct_exit; }
grep -q "ERR: ZG1 hot-sector CRC mismatch" <<<"$AFTER" &&
    pass "1: after fsck -r, ZG1's hot sector still fails its CRC -- left for the run that rebuilds it" ||
    fail "1: ZG1's damaged hot sector was restamped valid: $(grep -E 'ZG1' <<<"$AFTER" | head -2 | tr '\n' ' ')"
grep -q "NOTE: Zone Group 1 does not verify -- not editing it" <<<"$OUT" &&
    pass "2: fsck -r said it left ZG1 alone" || fail "2: no note: $(grep -E 'ZG1|Zone Group 1' <<<"$OUT" | head -3 | tr '\n' ' ')"
ct_exit
