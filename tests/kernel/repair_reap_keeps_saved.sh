#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reap that loses its swap leaves a live repair claim's saved row intact
#
# A repair claim keeps the registry row it borrowed in its own block, at
# CETRAFS_REPAIR_SAVED_OFF, so whoever reaps the claim after its
# repairer dies can put the registration back. A reap that judged a
# claim dead, and then lost its swap because the repairer renewed, must
# leave the live claim's saved row alone (audit 2026-11-06 L24). Since
# format 0x000A the saved row lies inside the sector the swap covers, so
# a miscompared reap writes nothing at all;
# repair_claim_saved_atomic covers the claim side of the same race.
#
# Staged on an LIO disk (512-byte sectors, real CAW): a live claim in row
# 2 borrowing a registered row; a reap judges it and is held
# (CETRAFS_TEST_REAP_GAP_SECS) while the claim renews. The reap must
# miscompare, and the saved row must still be there.
#
# DISCRIMINATION: a reap writing the rest of the block blind before its
# swap leaves the saved row zeroed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
RRP="$(ct_helper repair_reap_probe)"

IMG="$(ct_image 600 rreap)"
DISK="$(ct_lio_disks "$IMG" 1)" || { skip "no LIO loopback target here"; ct_exit; }
ct_mkfs "$DISK" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null

"$RRP" "$DISK" plant 2
S0="$("$RRP" "$DISK" show 2)"
grep -q "hb=5 saved=1 saved_ok=1" <<<"$S0" || { fail "setup: the planted claim reads '$S0'"; ct_exit; }
pass "setup: row 2 is a live claim borrowing a registered row ($S0)"

CETRAFS_TEST_REAP_GAP_SECS=3 "$RRP" "$DISK" reap 2 &
RP=$!
sleep 1
"$RRP" "$DISK" renew 2
RC=0
wait "$RP" || RC=$?
[ "$RC" = 0 ] || { [ "$RC" = 3 ] && { skip "the probe cannot reap here"; ct_exit; }; fail "setup: the reap probe failed ($RC)"; ct_exit; }
S1="$("$RRP" "$DISK" show 2)"
log "after the reap: $S1"
grep -q "hb=6 " <<<"$S1" || { fail "setup: the claim is not the renewed one ($S1) -- the reap did not miscompare"; ct_exit; }
pass "setup: the reap lost its swap to the renewal"
grep -q "saved=1 saved_ok=1" <<<"$S1" && pass "the live claim's saved row is intact" ||
    fail "the live claim's saved row was erased by the reap that lost ($S1)"
ct_exit
