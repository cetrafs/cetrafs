#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a fence leaves its trace in the victim's row, and both logs name the rows and labels
#
# A node that revokes a peer's lease bumps the peer's fence_epoch and
# nothing else: the row said that something had been fenced, not by whom
# or why, and the fencer's log named a row number with no host (audit
# O8). The fence now stamps fenced_by (the fencer's row), fence_reason and
# fenced_at into the victim's row in the same compare-and-write.
#
#  A. a real reclaim (a stale peer's zone group taken on a heartbeat
#     tick, zg_stale_reclaim.sh's staging) fences peer row 1: row 1 reads
#     fenced_by = this node's row, fence_reason = RECLAIM, fenced_at set
#  B. the fencer's log names the victim row and label, and the fencer's
#     own row and label, and the reason
#  C. the victim's log: a lease revoked by a peer (node_poke --fence, the
#     peer's fence as the fencer would write it) names the fencer's row,
#     its label and the reason, and the node stops writing
#
# DISCRIMINATION: TEST ONLY fence_trace_off makes a fence stamp nothing.
# FENCE_TRACE_NEGATIVE=1 sets it before A, and the suite must then FAIL
# at A (fenced_by and reason stay 0): it is the negative control, run by
# hand.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 fencetrace)"
LOOP="$(ct_loop "$IMG")"
MNT="$(ct_mnt fencetrace)"
ct_mkfs_small "$LOOP" >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"
ME="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$LOOP")/info")"
[ -n "$ME" ] || { fail "setup: cannot read this node's row"; ct_exit; }
ME_LABEL="$(uname -n | head -c 32)"
ct_umount "$MNT"

# ------------------------------------------------------------------ A, B
log "A/B: a reclaim of a stale peer's zone group fences its row, and says so"
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$LOOP" 1 aa
# This node's row is 0, the value an unwritten fenced_by reads as too, so
# plant a sentinel fencer first: a stamp that does not land leaves it.
"$NPOKE" "$LOOP" 1 --fence 4095 0 >/dev/null
ZG_POKE="$(ct_helper zg_poke)"
"$ZG_POKE" "$LOOP" 0 1 >/dev/null
if [ -n "${FENCE_TRACE_NEGATIVE:-}" ]; then
    log "NEGATIVE: the TEST ONLY fence_trace_off knob is set before A"
    ct_param_set fence_trace_off 1
fi
MARK="$(dmesg_mark)"
mount -t cetrafs "$LOOP" "$MNT"
wait_out_stale_window
sleep $((TEST_HB_SECS * 2))
LOG_A="$(dmesg_since "$MARK")"
ROW1="$("$NPOKE" "$IMG" 1 2>&1)"
ct_umount "$MNT" 2>/dev/null || true

by="$(sed -n 's/.*fenced_by=\([0-9]*\).*/\1/p' <<<"$ROW1")"
reason="$(sed -n 's/.*fence_reason=\([0-9]*\).*/\1/p' <<<"$ROW1")"
at="$(sed -n 's/.*fenced_at=\([0-9]*\).*/\1/p' <<<"$ROW1")"
epoch="$(sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' <<<"$ROW1")"
if [ "${epoch:-0}" -ge 1 ]; then
    pass "A: the reclaim revoked peer row 1's lease (fence_epoch $epoch)"
else
    fail "A: setup: no reclaim fenced row 1 -- the ZG was not taken from it (row: $ROW1)"
fi
[ "$by" = "$ME" ] && pass "A: the victim row names this node's row ($ME) as its fencer" ||
    fail "A: the victim row's fenced_by is '$by', want this node's row $ME"
[ "$reason" = 1 ] && pass "A: and records the reason (1 = reclaim)" ||
    fail "A: the victim row's fence_reason is '$reason', want 1 (reclaim)"
[ "${at:-0}" -gt 0 ] && pass "A: and the time of the fence" || fail "A: the victim row carries no fence time"

grep -qF "revoked stale node 1's lease" <<<"$LOG_A" &&
    grep -qF "victim row 1 (label " <<<"$LOG_A" &&
    grep -qF "fenced by row $ME (label $ME_LABEL)" <<<"$LOG_A" &&
    grep -qF "reason reclaim" <<<"$LOG_A" &&
    pass "B: the fencer's log names the victim row and label, the fencer's row and label, and the reason" ||
    fail "B: the fencer's log does not name both rows and labels: $(grep 'fence:' <<<"$LOG_A" | tail -2)"

# ---------------------------------------------------------------- C
log "C: a lease revoked by a peer is said in the victim's own log"
# Put the fence in this node's row the way a peer's fence writes it, while
# the node is mounted and beating. The peer is row 1, labelled.
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
"$NPOKE" "$IMG" "$ME" --fence 1 1 >/dev/null
blockdev --flushbufs "$LOOP"
sleep $((TEST_HB_SECS * 2 + 1))
LOG_C="$(dmesg_since "$MARK")"
grep -qF "this node's lease was revoked: fenced by row 1 (label " <<<"$LOG_C" &&
    grep -qF "reason reclaim" <<<"$LOG_C" &&
    pass "C: the victim's log names the fencer's row and the reason" ||
    fail "C: the victim's log does not name the fencer: $(grep -i 'lease\|fence' <<<"$LOG_C" | tail -2)"
if ! ( : >>"$MNT/after-fence" ) 2>/dev/null; then
    pass "C: and the revoked node stops writing"
else
    fail "C: a write landed after the lease was revoked"
fi
ct_umount "$MNT" 2>/dev/null || true
ct_param_set fence_trace_off 0
ct_exit
