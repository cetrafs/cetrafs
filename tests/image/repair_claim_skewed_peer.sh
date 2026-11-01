#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r never takes a live node's registry row, however far behind that node's clock is
#
# A repair claims a Node Registry row (state REPAIR) so no node can
# mount halfway through it. With no FREE row left it borrows one whose
# node has gone -- and "gone" was judged by comparing the row's
# last_seen against THIS machine's clock: older than the staleness
# window, borrowable. That is the comparison devutil.h warns against
# (two real nodes were found 1h55m apart): a live node whose clock lags
# by more than the window had its row overwritten by the claim. And the
# live-peer probe that runs next could no longer see it -- its row now
# read REPAIR -- so the repair went ahead on a mounted volume.
#
# Set up: every row is taken. Row 0 is a live node with its clock ten
# minutes behind (hb_seq advancing, last_seen old); every other row is a
# clean departure (last_seen == 0, which proves departure without any
# clock). The claim must take a departed row, and the probe must then
# find row 0 beating and refuse.
#
# DISCRIMINATION (measured on the unfixed code): the claim takes row 0,
# the probe finds nobody, and the repair runs.
#
# No kernel module and nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 skewpeer)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

"$NODE_POKE" "$DEV" 0 1 aa $(($(date +%s) - 600)) >/dev/null
rows=1
while "$NODE_POKE" "$DEV" "$rows" 1 bb 0 >/dev/null 2>&1; do rows=$((rows + 1)); done
[ "$rows" -ge 2 ] && pass "registry full: row 0 a live node 10 min behind, rows 1..$((rows - 1)) cleanly departed" ||
    { fail "setup: only $rows registry row(s)"; ct_exit; }
blockdev --flushbufs "$DEV"

export CETRAFS_PEER_PROBE_SECS=4
beat() {
    for _ in $(seq 1 40); do
        "$NODE_POKE" "$DEV" 0 --beat-keep-time >/dev/null 2>&1 || true
        sleep 0.5
    done
}
beat &
BEATER=$!
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" || true
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
unset CETRAFS_PEER_PROBE_SECS

claimed="$(sed -n 's/.*claimed registry row \([0-9]*\).*/\1/p' <<<"$OUT")"
if [ -n "$claimed" ] && [ "$claimed" != 0 ]; then
    pass "the repair claimed row $claimed, a departed node's"
else
    fail "the repair claimed row '${claimed:-none}' -- the live node's row (its clock is merely behind ours)"
fi
if grep -q "is mounted by another node (registry row 0" <<<"$OUT"; then
    pass "the repair refused: row 0 is heartbeating"
else
    fail "the repair did not refuse the live node: $(grep -E 'ERR|OK|claimed' <<<"$OUT" | head -3 | tr '\n' ' ')"
fi
st="$("$NODE_POKE" "$DEV" 0)"
grep -q '^state=1 ' <<<"$st" && pass "row 0 is still the live node's ($st)" ||
    fail "row 0 no longer belongs to the live node: $st"

# B: nobody left cleanly -- every other row is a node that crashed (old
# last_seen, never changing). Only watching can tell them from row 0, so
# the claim waits a probe window and borrows a row that did not move.
log "B: no clean departure to borrow; the claim must watch the rows first"
for r in $(seq 1 $((rows - 1))); do "$NODE_POKE" "$DEV" "$r" 1 bb $(($(date +%s) - 900)) >/dev/null; done
blockdev --flushbufs "$DEV"
export CETRAFS_PEER_PROBE_SECS=4
beat &
BEATER=$!
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" || true
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
unset CETRAFS_PEER_PROBE_SECS
claimed="$(sed -n 's/.*claimed registry row \([0-9]*\).*/\1/p' <<<"$OUT")"
if [ -n "$claimed" ] && [ "$claimed" != 0 ]; then
    pass "B: the repair claimed row $claimed, one that did not move while watched"
else
    fail "B: the repair claimed row '${claimed:-none}' -- the live node's"
fi
grep -q "is mounted by another node (registry row 0" <<<"$OUT" &&
    pass "B: the repair refused: row 0 is heartbeating" ||
    fail "B: the repair did not refuse the live node: $(grep -E 'ERR|OK|claimed' <<<"$OUT" | head -3 | tr '\n' ' ')"

ct_exit
