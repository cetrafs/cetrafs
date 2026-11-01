#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Block Group claimed from the unowned pool accepts this node's count deltas
#
# Every Block Group's free count carries an ownership epoch
# (reconcile_seq): a delta is applied only if it was accrued under the
# epoch on the device, so a stale owner's delta cannot land on top of a
# new owner's recount. A node learns the epoch when ownership ENTERS its
# cache -- a ZG claim reconciles, a re-attach seeds it.
# cetrafs_bg_claim_free() did neither: the claimed Block Group kept the
# in-memory epoch of 0 it was mounted with, and any Block Group that had
# ever been reconciled has an on-disk epoch of at least 1. Every delta
# for it was then refused ("dropped: the count was reconciled by a new
# owner"), so its count stayed at "all free" while it filled up -- which
# the empty-BG release path, deciding on that count, takes at its word.
#
# bg_claim_free.sh never saw it: its Block Group has never been
# reconciled, so its epoch is still 0 and happens to match. Here it has
# been (the state of any Block Group a takeover ever recounted and that
# was later released), and that is asserted before anything is measured.
#
# DISCRIMINATION (measured on the unfixed code): dmesg shows the claimed
# Block Group's delta dropped, and fsck finds its cached free count above
# what its bitmap says by everything allocated before the first flush.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 1200 bgepoch)"
MNT="$(ct_mnt bgepoch)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null

# A Block Group's epoch moves when its count is reconciled by a NEW
# owner -- a peer taking over a stale node's Zone Group. A mount alone
# does not do it (measured: epoch still 0). --bumpseq advances it exactly
# as that reconcile would; then the Block Group goes back to the pool, as
# a release of an empty one leaves it.
"$POKE" "$DEV" 1 --bumpseq >/dev/null
"$POKE" "$DEV" 1 --owner "$FREE_MARK" >/dev/null
seq="$("$POKE" "$DEV" 1 --dump | sed -n 's/.*reconcile_seq=\([0-9]*\).*/\1/p')"
if [ "${seq:-0}" -ge 1 ]; then
    pass "BG 1 is unowned with a nonzero ownership epoch ($seq), as after a release"
else
    fail "BG 1's epoch is '${seq:-?}' -- epoch 0 hides the bug, the setup is not what this measures"
fi

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
# Fill only until BG 1 has been claimed, then write one more file into
# it and stop: running on to ENOSPC triggers the allocator's own
# reconcile, which recounts the bitmap and hides the drift -- the state
# a real volume sits in is "claimed and partly used".
bg1_owner() { "$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}'; }
i=0
while [ "$(bg1_owner)" = "$FREE_MARK" ] && [ "$i" -le 200 ]; do
    dd if=/dev/urandom of="$MNT/f$i" bs=1M count=16 status=none 2>/dev/null || break
    i=$((i + 1))
done
dd if=/dev/urandom of="$MNT/after" bs=1M count=64 status=none
i=$((i + 4))
sync
ct_umount "$MNT"
klog="$(dmesg_since "$MARK")"

claimed="$("$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
written_mib=$((i * 16))
if [ "$claimed" != "$FREE_MARK" ]; then
    pass "BG 1 was claimed (now ZG $claimed) and written into (${written_mib} MiB total)"
else
    fail "BG 1 owner=$claimed after ${written_mib} MiB -- the claim path was not exercised"
fi

if grep -q "BG 1 free delta .* dropped" <<<"$klog"; then
    fail "deltas for the claimed BG were refused: $(grep -m1 'BG 1 free delta' <<<"$klog")"
else
    pass "no delta for the claimed BG was refused"
fi

out="$(ct_fsck "$DEV" 2>&1 || true)"
log "fsck: $(grep -E '^(ERR|WARN)' <<<"$out" | head -3 | tr '\n' ' ')$("$POKE" "$DEV" 1 --dump)"
if grep -qE 'BG1 cached free_data_blocks|ZG[0-9]+ aggregate free_data_blocks' <<<"$out"; then
    fail "free counts disagree with the bitmap after the claim: $(grep -m1 -E 'BG1 cached|aggregate' <<<"$out")"
else
    pass "BG 1's free count matches its bitmap after the claim"
fi

ct_exit
