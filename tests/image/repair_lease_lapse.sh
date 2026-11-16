#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repairer whose own renewal stalled past its lease writes nothing more
#
# A tool's registry claim is judged dead by a watcher (a mounting node,
# another tool) once its hb_seq has not moved for CETRAFS_REPAIR_PROBE_SECS
# at the least, and reaped. The tool itself never asked how long ago its
# last renewal landed, so a repairer whose paths stalled kept writing
# after a node may have reaped its claim and mounted (audit 2026-11-15
# BM-64, BM-65). Now a renewal older than the lease (two intervals) stops
# every further repair write, one-way.
#
# A Block Group's cached free count is made wrong, so fsck -r's block
# group pass has a descriptor to rewrite; fsck -r is held just before
# that pass and one renewal is stuck for 12 s
# (CETRAFS_TEST_REPAIR_RENEW_STALL_SECS):
#   1. fsck stops, saying its claim was not renewed in time;
#   2. the descriptor still carries the wrong count.
#
# DISCRIMINATION: CETRAFS_TEST_REPAIR_NO_LEASE=1 (no lease, as before):
# the pass repairs the count after the stall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
BGPOKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3
IMG="$(ct_image 600 rll)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
bg0_free() { "$MAP" "$DEV" | sed -n 's/^bg 0 .* free=\([0-9]*\)\/.*/\1/p'; }
TRUE_FREE="$(bg0_free)"
[ -n "$TRUE_FREE" ] && [ "$TRUE_FREE" -gt 10 ] || { fail "setup: could not read BG0's free count ($TRUE_FREE)"; ct_exit; }
WRONG=$((TRUE_FREE - 7))

# run <out> <no_lease 0|1> -> fsck's rc
run() {
    local rc=0
    "$BGPOKE" "$DEV" 0 "$WRONG" >/dev/null
    if [ "$2" = 1 ]; then
        CETRAFS_TEST_REPAIR_NO_LEASE=1 CETRAFS_TEST_REPAIR_RENEW_STALL_SECS=12 \
            CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=14 "$FSCK" -r "$DEV" >"$1" 2>&1 || rc=$?
    else
        CETRAFS_TEST_REPAIR_RENEW_STALL_SECS=12 \
            CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=14 "$FSCK" -r "$DEV" >"$1" 2>&1 || rc=$?
    fi
    echo "$rc"
}

O="$(ct_tmp rll-out)"
RC="$(run "$O" 1)"
F="$(bg0_free)"
log "control (no lease): rc=$RC, BG0 free $WRONG -> $F (true $TRUE_FREE)"
grep -q "holding before the block group pass" "$O" || { fail "setup: fsck never reached the hold: $(tail -3 "$O")"; ct_exit; }
[ "$F" = "$TRUE_FREE" ] && pass "control: with no lease, the pass repaired the count after the stalled renewal" ||
    fail "control: the count was not repaired without the lease ($F) -- the suite does not reach the write: $(grep -m2 ERR "$O")"

RC="$(run "$O" 0)"
F="$(bg0_free)"
log "lease: rc=$RC, BG0 free $F"
grep -q "not renewed in time" "$O" && [ "$RC" -gt 1 ] && pass "1: fsck -r stopped: its claim was not renewed in time (rc $RC)" ||
    fail "1: rc=$RC, no lease stop: $(grep -m2 ERR "$O")"
[ "$F" = "$WRONG" ] && pass "2: the descriptor was not rewritten after the lapse" || fail "2: BG0 free is $F, want $WRONG"
ct_exit
