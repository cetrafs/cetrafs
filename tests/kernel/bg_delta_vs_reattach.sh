#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a delta accrued BEFORE a zone group changed hands must not survive its return
#
# The sibling of bg_delta_vs_steal.sh, for the case that suite does not
# reach. There, a peer steals the ZG and this node's stale delta is refused
# at the flush because the descriptor's epoch no longer matches the one this
# node cached. What it never does is give the ZG BACK.
#
# When it comes back -- a peer that took it then died, and this node
# reclaims it -- the claim RECONCILES the member Block Groups from their
# bitmaps and re-seeds this node's cached epoch to the new value. The epoch
# the apply compares against is read at FLUSH time, not captured when the
# delta was accrued, so re-seeding made a delta older than the reconcile
# look current: it applied on top of a recount that already contained it.
#
# Seen in the field on a three-node volume. A VM image held open for days
# accrues for as long as it stays open, so the delta easily outlives an
# ownership event; the counts were driven below zero and the refusal then
# re-accrued them, which looped forever:
#   BG 61 free delta -15196 would take the count below zero (0)
#   BG 61 free delta -15196 could not be applied (-22) -- re-accrued ...
#   heartbeat: surplus ZG release pass failed: -22
# every 15 seconds, with the surplus-release pass wedged behind it. The
# underflow is only the LOUD half: a delta small enough to still fit would
# have corrupted the count silently.
#
# Discrimination: drop the discard from cetrafs_sb_set_bg_epoch() and the
# stale delta lands on the reconciled count, so the first assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 bgreatt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgreatt)"
ct_mkfs_small "$DEV" >/dev/null

bg0()      { "$BG_POKE" "$DEV" 0 --dump; }
bg0_free() { bg0 | grep -oP 'free_data_blocks=\K[0-9]+'; }
bg0_seq()  { bg0 | grep -oP 'reconcile_seq=\K[0-9]+'; }

# A peer that is REGISTERED and demonstrably dead, planted before mount so
# the kernel's own cached copy of the registry cannot overwrite the poke.
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Allocate in BG0, flushed, so the on-disk count is settled and real.
dd if=/dev/zero of="$MNT/f" bs=4096 count=256 conv=fsync status=none
sync
sleep 1
BASE_FREE="$(bg0_free)"
BASE_SEQ="$(bg0_seq)"
log "settled: free=$BASE_FREE seq=$BASE_SEQ"

# Accrue a delta and keep it pending: the fd stays open, so no durability
# boundary fires and nothing flushes it.
exec 9<>"$MNT/f"
fallocate -p -o 0 -l $((256 * 4096)) "$MNT/f"
[ "$(bg0_free)" = "$BASE_FREE" ] ||
    fail "the count moved on disk before any flush ($BASE_FREE -> $(bg0_free)) -- there is no pending delta to test"
pass "a free-count delta is accrued and still pending"

# The ZG changes hands and comes back. On a real cluster that is a peer
# taking it and then dying; single-node, the observable part is the same
# and is reached directly: the descriptor's epoch advances (what that
# peer's reconcile does), and this node forgets owning the ZG (what
# losing it does), so the next tick RE-ATTACHES and re-seeds the epoch.
# That re-seed is the moment the pre-handover delta has to be discarded.
MARK="$(dmesg_mark)"
"$BG_POKE" "$DEV" 0 --bumpseq >/dev/null
STOLEN_SEQ="$(bg0_seq)"
[ "$STOLEN_SEQ" != "$BASE_SEQ" ] ||
    fail "the epoch did not advance ($BASE_SEQ), so there is no handover to re-attach from"
ct_param_set test_uncache_zg 0
sleep $((TEST_HB_SECS * 3))

LOG="$(dmesg_since "$MARK")"
echo "$LOG" | grep -q 'forgetting ownership of ZG 0' ||
    fail "the test lever never fired, so no re-attach happened: $(echo "$LOG" | tail -3)"
pass "the zone group was re-attached, re-seeding BG0's count epoch"

RECONCILED="$(bg0_free)"
log "after the handover: free=$RECONCILED seq=$(bg0_seq)"

# THE assertion: flush now, and the pre-handover delta must not land on the
# count the recount just wrote.
exec 9>&-
sync
blockdev --flushbufs "$DEV"
sleep 1

NOW="$(bg0_free)"
[ "$NOW" = "$RECONCILED" ] &&
    pass "the pre-handover delta did not land on the count the new epoch carries (still $NOW)" ||
    fail "a delta accrued before the handover was applied over it: $RECONCILED -> $NOW -- double counted"

dmesg_since "$MARK" | grep -q 'dropping an accrued free delta' &&
    pass "and the discard says so rather than happening silently" ||
    fail "no warning logged for the dropped delta: $(echo "$LOG" | grep -i 'BG 0' | tail -3)"

# The loop the field hit: a delta that cannot be applied must never be
# re-accrued forever.
dmesg_since "$MARK" | grep -q 'could not be applied' &&
    fail "a delta is being re-accrued and retried -- this is the 15-second loop, not a fix" || true
pass "no delta is stuck re-accruing"

ct_umount "$MNT"
# Hand the ZG back from the peer that was never real, then let fsck settle
# the counts the simulated handover deliberately left lagging.
"$ZG_POKE" "$DEV" 0 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after repairing the deliberately-lagging counts" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

ct_exit
