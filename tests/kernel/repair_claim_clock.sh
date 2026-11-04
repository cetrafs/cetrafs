#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim is judged live by its renewals, never by comparing clocks, and is renewed in every phase
#
# fsck -r and growfs hold a Node Registry row in state REPAIR while they
# write, and a mount -- or a second repair -- refuses while that claim is
# live. Live was decided by comparing the row's last_seen with the
# observer's own clock, the comparison the live-peer probe gave up long
# ago (two real nodes were found 1h55m apart):
#
#  A. a live repairer whose clock is behind ours by more than the
#     staleness window looked expired, and a node mounted mid-repair;
#  B. a dead repairer whose last_seen lies in our future blocked every
#     mount until our clock caught up;
#  C. and the claim was renewed only from fsck's inode loops -- any
#     other phase, and all of growfs, let it lapse while still writing;
#  D. a second fsck -r likewise ran beside a live, skewed one.
#
# Now the claim is renewed on a timer and observers watch hb_seq.
#
# DISCRIMINATION (measured on the unfixed code): A mounts, B is refused,
# C's row does not move during the hold, D proceeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
# A dead repair claim is watched for the whole stale window (120 s by
# default) before a mount goes past it; B pays that once.
ct_param_set stale_secs 20

DEV="$(ct_dev 560 repclock)"
MNT="$(ct_mnt repclock)"
ct_mkfs_small "$DEV" >/dev/null
hbseq() { sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p' <<<"$("$NODE_POKE" "$DEV" "$1")"; }

log "C: fsck -r renews its claim through a phase that does no inode work"
(CETRAFS_TEST_REPAIR_HOLD_SECS=14 "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true) &
FSCK=$!
sleep 2
s1="$(hbseq 0)"
sleep 10
s2="$(hbseq 0)"
st="$("$NODE_POKE" "$DEV" 0)"
wait "$FSCK" || true
if grep -q '^state=2 ' <<<"$st" && [ "${s2:-0}" -gt "${s1:-0}" ]; then
    pass "C: the claim renewed while the repair did no inode work (hb_seq $s1 -> $s2)"
else
    fail "C: the claim did not renew during a quiet phase (hb_seq $s1 -> $s2, row: $st)"
fi

# A skewed live repairer, played on row 1: beats, but last_seen far behind.
skewed_repairer() { # <last_seen> -- then keeps beating for ~25 s
    "$NODE_POKE" "$DEV" 1 2 aa "$1" >/dev/null
    ( for _ in $(seq 1 25); do "$NODE_POKE" "$DEV" 1 --beat-keep-time >/dev/null 2>&1 || true; sleep 1; done ) &
    REPAIRER=$!
}

log "D: a second fsck -r beside a live repairer whose clock is 30 min behind"
skewed_repairer $(($(date +%s) - 1800))
out="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" || true
kill "$REPAIRER" 2>/dev/null || true
wait "$REPAIRER" 2>/dev/null || true
grep -q "already being repaired" <<<"$out" && pass "D: the second repair refused" ||
    fail "D: a second repair ran beside a live one: $(grep -E 'claimed|OK' <<<"$out" | head -2 | tr '\n' ' ')"

log "A: a mount beside a live repairer whose clock is 30 min behind"
skewed_repairer $(($(date +%s) - 1800))
rc=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
kill "$REPAIRER" 2>/dev/null || true
wait "$REPAIRER" 2>/dev/null || true
if [ "$rc" != 0 ]; then
    pass "A: the mount was refused while the repair renewed its claim"
else
    umount "$MNT"
    fail "A: a node mounted in the middle of a live repair"
fi

log "B: a dead repairer whose last_seen is 30 min in our future"
"$NODE_POKE" "$DEV" 1 2 aa $(($(date +%s) + 1800)) >/dev/null
if ct_mount "$DEV" "$MNT"; then
    require_cetrafs_mount "$MNT"
    pass "B: mounted -- the claim did not move, so its repairer is gone"
    ct_umount "$MNT"
else
    fail "B: a dead repairer's claim blocks the volume because its clock is ahead"
fi

ct_exit
