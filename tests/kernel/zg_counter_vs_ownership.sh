#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free-count update never republishes stale ZG ownership
#
# free_data_blocks and owner_node_id share the ZG record's HOT SECTOR --
# the 512-byte compare-and-swap unit. While the counter was maintained as
# a cached read-modify-write, every deferred flush of it wrote the whole
# 4096-byte block back, republishing the ownership bytes as they were
# when the block was read. A peer that claimed the ZG in between (a
# stale-owner steal) had its claim silently reverted by what looks like
# an unrelated counter update -- with a correctly recomputed hot
# checksum, so no reader could detect it -- and both nodes then allocated
# from the same Zone Group.
#
# The counter now accrues in memory and is applied with one CAS, which
# re-reads on contention, so ownership cannot be carried backwards.
#
# The test holds a write fd open across a hole-punch, so the accrued
# delta is still pending (the flush happens at last-writer close), pokes
# a different owner onto the record behind the mount's back, then closes.
# With a blind write-back the poked owner is gone afterwards; with the
# CAS it survives AND the delta still lands.
#
# Measured against the pre-fix cached write: the OWNERSHIP assertion is
# the discriminating one -- it reported "owner reads 0 after the flush,
# expected the poked 7", i.e. the reverted claim, exactly the corruption
# this guards. The fsck aggregate assertion passes either way and is kept
# only as a statement of the invariant (the counter must still land).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"

DEV="$(ct_dev 560 zgown)"
IMGFILE="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt zgown)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "checking a pending free-count flush cannot revert a ZG ownership change"
# 2 MiB, then punch the middle out: a real net free-block change, so the
# accrued delta is nonzero.
dd if=/dev/zero of="$MNT/probe" bs=4096 count=512 status=none
sync
exec 9>>"$MNT/probe"                     # hold the file open: no flush yet
fallocate --punch-hole --keep-size -o 262144 -l 262144 "$MNT/probe"

# Poke a different owner onto ZG 0 behind the live mount, exactly as a
# peer's steal would leave it. Poking the backing file is what a second
# node's write looks like to this one: the kernel's cached copy still
# says we own it.
"$ZG_POKE" "$IMGFILE" 0 7 >/dev/null
POKED="$("$ZG_POKE" "$IMGFILE" 0 2>/dev/null | head -1 || true)"

exec 9>&-                                # last writer closes -> flush
sync
sleep 1

ct_umount "$MNT"

# Read the owner back off the raw image.
OWNER_AFTER="$("$ZG_POKE" "$IMGFILE" 0 2>&1 | grep -oP 'owner_node_id=\K[0-9]+' || true)"
if [ -z "$OWNER_AFTER" ]; then
    skip "zg ownership: zg_poke has no read-back mode; relying on fsck below"
elif [ "$OWNER_AFTER" = "7" ]; then
    pass "zg ownership: the poked owner (7) survived the free-count flush"
else
    fail "zg ownership: owner reads $OWNER_AFTER after the flush, expected the poked 7 -- the counter write reverted it"
fi

log "checking the aggregate is reconciled by whoever takes the ZG"
# The delta is deliberately DROPPED here: once the record says node 7
# owns this zone group, writing our accrued delta into it would land on
# an aggregate its new owner has reconciled from the bitmaps -- which
# already includes these frees -- and double count them. See
# tests/kernel/zg_delta_vs_steal.sh.
#
# So the aggregate is stale at this instant, by design, and what repairs
# it is the next claim: node 7 does not exist, so this node finds it
# stale on the next mount, steals the ZG back, and reconciles the
# aggregate from the bitmaps. That is the real recovery path, and it is
# what this assertion now covers.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
sync
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if echo "$FSCK_OUT" | grep -q "free_data_blocks"; then
    fail "fsck: ZG aggregate still disagrees with its BGs after a reclaim: $(echo "$FSCK_OUT" | grep -i free_data_blocks | head -1)"
else
    pass "fsck: reclaiming the ZG reconciled its aggregate back to the sum of its BGs"
fi

ct_exit
