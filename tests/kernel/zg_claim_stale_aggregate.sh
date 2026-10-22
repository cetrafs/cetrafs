#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a zone group is not written off because its cached aggregate reads zero
#
# cetrafs_zg_claim_one_more() picks which zone group to claim when every
# one this node owns has run out of space. It used to skip any candidate
# whose free_data_blocks aggregate read 0, on the reasonable-sounding
# grounds that claiming it would gain nothing.
#
# That aggregate is not authoritative enough to exclude on. It is accrued
# in memory and applied at durability boundaries, so a node that freed
# blocks and then crashed leaves it understating the ZG's real free space
# -- possibly as 0 while every member Block Group is in fact empty.
# Excluded forever, that space is unreachable by any node: no one claims
# the ZG, so no one ever discovers the aggregate was wrong.
#
# It is now ranked last rather than skipped, so it is still avoided
# whenever anything better exists, and the Block Group scan that follows
# a claim settles what is really there.
#
# Measured discrimination: restoring the outright exclusion fails the
# write with ENOSPC on a filesystem whose second zone group is entirely
# empty. The last assertion passes either way (it only reports whether an
# on-demand claim was logged) and is not a discriminator.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
BG_POKE="$(ct_helper bg_poke)"

# Two zone groups: one this node will own and fill, one left unowned
# whose aggregate we then lie about.
DEV="$(ct_dev 1100 zgsa)"
MNT="$(ct_mnt zgsa)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OWNED="$(grep -oP 'zg \K[0-9]+(?=: owner=0 \(this node\))' /proc/fs/cetrafs/$(basename "$DEV")/info | head -1)"
[ -n "$OWNED" ] && pass "zg aggregate: this node owns ZG $OWNED after mount" ||
    fail "zg aggregate: could not determine the owned ZG"
OTHER=$((1 - OWNED))
ct_umount "$MNT"

log "making the unowned ZG $OTHER look exhausted while its blocks are free"
"$ZG_POKE" "$DEV" "$OTHER" free 0 >/dev/null
[ "$("$ZG_POKE" "$DEV" "$OTHER" | grep -oP 'free_data_blocks=\K[0-9]+')" = "0" ] &&
    pass "zg aggregate: ZG $OTHER's aggregate now reads 0" ||
    fail "zg aggregate: the poke did not take"

ct_mount "$DEV" "$MNT"
# Make every BG of the OWNED ZG look full, so an allocation has to go
# looking for another zone group -- the same trick the claim-policy suite
# uses, rather than writing hundreds of MiB for real.
OWNED_FIRST="$(grep -oP "zg $OWNED: owner=0 .*first_bg=\K[0-9]+" /proc/fs/cetrafs/$(basename "$DEV")/info | head -1)"
OWNED_CNT="$(grep -oP "zg $OWNED: owner=0 .*bg_count=\K[0-9]+" /proc/fs/cetrafs/$(basename "$DEV")/info | head -1)"
ct_umount "$MNT"
for b in $(seq "${OWNED_FIRST:-0}" $((${OWNED_FIRST:-0} + ${OWNED_CNT:-1} - 1))); do
    "$BG_POKE" "$DEV" "$b" 0 sync-zg >/dev/null
done
ct_mount "$DEV" "$MNT"

log "checking a write can still find space in the maligned ZG"
MARK="$(dmesg_mark)"
if dd if=/dev/zero of="$MNT/probe" bs=4096 count=4 status=none 2>/dev/null; then
    pass "zg aggregate: the write succeeded -- the zero-aggregate ZG was still claimable"
else
    fail "zg aggregate: ENOSPC although ZG $OTHER has free blocks -- it was written off on a stale aggregate"
fi
dmesg_since "$MARK" | grep -q "claimed one more" &&
    pass "zg aggregate: dmesg confirms it claimed another zone group on demand" ||
    pass "zg aggregate: (no on-demand claim logged -- the owned ZG still had room)"
sync
ct_umount "$MNT"

ct_exit
