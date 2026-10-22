#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a BG free-count delta is never applied over a new owner's reconcile
#
# The sibling of zg_delta_vs_steal.sh, for the Block Group half. The ZG
# aggregate moved to accrue-in-memory + ownership-checked CAS long ago; the
# BG descriptor kept the cached read-modify-write -- which left a DIRTY
# BUFFER that ordinary background writeback (or the next flush boundary)
# could land at any moment. A node declared stale while alive would then
# overwrite the counts a stealing peer had just reconciled from the
# bitmaps, correctly checksummed, undetectable. v0x0004 gives the
# descriptor a reconcile_seq (the count's ownership EPOCH, advanced by
# every reconcile) and applies deltas by a CAS that refuses an image whose
# epoch is not the one the delta was accrued under -- value comparison
# cannot work, since a recount can be byte-identical to what the stale
# node expects; the epoch cannot.
#
# The steal is simulated exactly as the ZG suite simulates its own: poke
# the thief's on-disk marker (here --bumpseq, the reconcile's epoch
# advance) while this node holds an unflushed delta, then force the flush
# and assert the delta was DROPPED, loudly. Discrimination: with the epoch
# guard removed from the mutator, the delta applies over the "reconciled"
# count and the first assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 bgsteal)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgsteal)"
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

bg0() { "$BG_POKE" "$DEV" 0 --dump; }
bg0_free() { bg0 | grep -oP 'free_data_blocks=\K[0-9]+'; }
bg0_seq() { bg0 | grep -oP 'reconcile_seq=\K[0-9]+'; }

dd if=/dev/zero of="$MNT/f" bs=4096 count=64 conv=fsync status=none
sync
BASE_FREE="$(bg0_free)"
BASE_SEQ="$(bg0_seq)"
[ "$BASE_SEQ" -ge 1 ] && pass "the claim-time reconcile stamped an epoch (reconcile_seq=$BASE_SEQ)" ||
    fail "reconcile_seq=$BASE_SEQ after mount+write -- reconcile is not advancing the epoch"

log "control first: with no steal, a delta flushes normally through the CAS"
# Runs BEFORE the simulated steal, deliberately: the steal below leaves this
# node's in-memory epoch mismatched for good (nothing re-reconciles until
# the next ownership transfer), after which EVERY delta is correctly
# dropped -- so a flush-works control can only run while the epochs agree.
echo more >"$MNT/g"
exec 8<>"$MNT/g"
fallocate -l $((16 * 4096)) "$MNT/g" 2>/dev/null || dd if=/dev/zero of="$MNT/g" bs=4096 count=16 conv=notrunc oflag=append status=none
PRE="$(bg0_free)"
exec 8<&- # close: the durability boundary fires
sync
sleep 1
[ "$(bg0_free)" != "$PRE" ] && pass "an un-stolen delta reaches the descriptor through the CAS ($PRE -> $(bg0_free))" ||
    fail "the count never moved for a legitimate flush -- the CAS path does not apply anything"
[ "$(bg0_seq)" = "$BASE_SEQ" ] && pass "and an ordinary apply does not touch the epoch" ||
    fail "reconcile_seq moved on a plain delta apply: $BASE_SEQ -> $(bg0_seq)"
BASE_FREE="$(bg0_free)"

# Accrue a delta without flushing: punch with the fd held open, so no
# durability boundary fires (same trick as the ZG suite).
exec 9<>"$MNT/f"
fallocate -p -o 0 -l $((64 * 4096)) "$MNT/f"
[ "$(bg0_free)" = "$BASE_FREE" ] && pass "the punch's delta is pending, not yet on disk" ||
    fail "the count moved on disk before any flush boundary ($BASE_FREE -> $(bg0_free)) -- nothing pending to test"

# Simulate the FULL steal: a peer that declared this node stale takes the
# ZG (owner -> 7, so the ZG-aggregate delta drops on its own check, exactly
# as zg_delta_vs_steal.sh proves) AND reconciles the member BG -- advancing
# the epoch. This node still believes it owns everything. MARK is taken
# FIRST: `blockdev --flushbufs` is BLKFLSBUF, which reaches ->sync_fs and
# fires the very flush under test, so a mark taken after it misses the
# drop's log line entirely (found the hard way).
MARK="$(dmesg_mark)"
"$ZG_POKE" "$DEV" 0 7 >/dev/null
"$BG_POKE" "$DEV" 0 --bumpseq >/dev/null
# The post-steal baseline is read BEFORE flushbufs for the same reason the
# mark is taken before it: the flush it fires is the event under test.
STOLEN_FREE="$(bg0_free)"
STOLEN_SEQ="$(bg0_seq)"
blockdev --flushbufs "$DEV"

sync   # belt and braces: flushbufs above already reached ->sync_fs
sleep 1

# THE assertion: the stale delta must not land on the thief's count.
NOW_FREE="$(bg0_free)"
[ "$NOW_FREE" = "$STOLEN_FREE" ] &&
    pass "the delta was not written over the new owner's reconcile (count $NOW_FREE unchanged)" ||
    fail "the stale delta LANDED over a reconciled count: $STOLEN_FREE -> $NOW_FREE -- the new owner's truth is now double counted"
[ "$(bg0_seq)" = "$STOLEN_SEQ" ] && pass "and the thief's epoch stands (reconcile_seq=$STOLEN_SEQ)" ||
    fail "reconcile_seq moved from $STOLEN_SEQ to $(bg0_seq) -- something rewrote the stolen descriptor"

dmesg_since "$MARK" | grep -q "dropped: the count was reconciled by a new owner" &&
    pass "and the drop says so rather than happening silently" ||
    fail "no warning logged for the dropped BG delta: $(dmesg_since "$MARK" | grep -i 'BG ' | tail -2)"

exec 9>&-
ct_umount "$MNT"
# Hand the ZG back (the "thief", node 7, was never real) and let fsck
# repair resolve what the simulated steal deliberately left behind: both
# dropped deltas mean the counts lag the bitmap by exactly the punch --
# the divergence a real next owner's reconcile, or fsck -r, exists to fix.
"$ZG_POKE" "$DEV" 0 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after repairing the deliberately-lagging counts" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
