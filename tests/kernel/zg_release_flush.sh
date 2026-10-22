#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a released Zone Group must not have a free-count delta left pending
#
# Free-space deltas are accrued in memory and applied at durability
# boundaries. cetrafs_zg_release_surplus() gave a zone group back
# WITHOUT flushing: it reads emptiness from the Block Group counters,
# which are updated in the buffer the moment blocks are freed, so a ZG
# reads "fully empty" while its aggregate delta is still unapplied.
# cetrafs_flush_dirty_free_counts() then applies that delta to a zone
# group this node no longer owns.
#
# Single-node that is merely stale. With a peer it is corruption: the
# peer reconciles the aggregate from the bitmaps when it claims the ZG
# -- which is the truth, and already includes these frees, because the
# bitmaps were updated while we still owned them -- and our late delta
# then adds on top. That aggregate is what statfs reports and what
# cetrafs_zg_claim_one_more() ranks candidates on.
#
# Reaching it needs a free whose delta is still pending when the
# heartbeat tick runs, and fallocate(PUNCH_HOLE) is the one free path
# that takes no namespace lock -- so it misses that flush boundary, and
# holding the file open misses the file-lock-close one too.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# 2 ZGs need 2 Block Groups, and 512 MiB is the smallest -b allows.
# Sparse, so only what is actually written costs real space.
IMG="$(ct_image 1200 zgrel)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgrel)"
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

# NO sync() here. sync(2) reaches ->sync_fs, which flushes exactly the
# pending free-count deltas this suite exists to catch outstanding --
# the first version of these helpers synced, and the measurement
# therefore destroyed the state it was measuring and passed against the
# broken build. blockdev --flushbufs drops the block device's cached
# pages without going through the filesystem at all.
# Read everything from procfs, nothing from the device. sync(2) AND
# `blockdev --flushbufs` both reach ->sync_fs, which flushes exactly the
# pending deltas this suite exists to catch outstanding -- the first
# version of this test read the on-disk aggregate and therefore
# destroyed the state it was measuring, passing against the broken
# build.
zg_owner()   { grep -oP "^\s+zg $1: owner=\K\S+" "$PROC/info"; }
pending()    { grep -oP '^zg_pending_deltas: \K[0-9]+' "$PROC/info"; }

# Force a second ZG to be claimed on demand, by making the first
# genuinely full (fill-bitmap, not a poked counter -- a mount
# reconciles a counter back from the bitmap).
INFO="$(cat "$PROC/info")"
ZG0_FIRST="$(echo "$INFO" | grep -P '^\s+zg 0:' | grep -oP 'first_bg=\K[0-9]+')"
ZG0_N="$(echo "$INFO" | grep -P '^\s+zg 0:' | grep -oP 'bg_count=\K[0-9]+')"
ct_umount "$MNT"
for ((bg = ZG0_FIRST; bg < ZG0_FIRST + ZG0_N; bg++)); do
    "$BG_POKE" "$DEV" "$bg" 0 fill-bitmap >/dev/null
done
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Allocate into ZG1, then close and sync so those deltas are applied and
# only the PUNCH's delta is outstanding below.
dd if=/dev/zero of="$MNT/f" bs=4096 count=64 conv=fsync status=none
sync
[ "$(pending)" = "0" ] && pass "no deltas outstanding once the allocation is flushed" ||
    fail "started with $(pending) pending deltas"
[ "$(zg_owner 1)" = "0" ] && pass "ZG1 was claimed on demand and is owned by this node" ||
    fail "ZG1 owner is $(zg_owner 1), expected this node -- the on-demand claim did not happen"

# Fastest beat the controls file allows (floor is CETRAFS_HB_INTERVAL_MIN_SECS);
# just needs a tick to fire promptly so the release pass runs.
echo "hb_interval_secs=5" >"$PROC/controls"

# Punch every block while HOLDING the file open. fallocate takes no
# namespace lock and the file never closes, so neither flush boundary
# fires: ZG1 is now empty by its Block Group counters, with its
# aggregate delta unapplied.
exec 9<>"$MNT/f"
fallocate -p -o 0 -l $((64 * 4096)) "$MNT/f"

# Prove the setup really built the state, rather than assuming it: if
# nothing is pending here, everything below passes for the wrong reason.
[ "$(pending)" -ge 1 ] &&
    pass "the punch leaves a delta pending ($(pending) ZG) with the file still open" ||
    fail "no delta pending after the punch -- something flushed, and this suite would prove nothing"

RELEASED=0
PENDING_AT_RELEASE=""
for _ in $(seq 1 30); do
    if [ "$(zg_owner 1)" = "none" ]; then
        PENDING_AT_RELEASE="$(pending)"
        RELEASED=1
        break
    fi
    sleep 1
done
[ "$RELEASED" = "1" ] && pass "the emptied ZG is released back" ||
    fail "ZG1 was never released (owner=$(zg_owner 1)) -- the assertion below proves nothing without it"

if [ "$RELEASED" = "1" ]; then
    [ "$PENDING_AT_RELEASE" = "0" ] &&
        pass "and nothing was left pending for it" ||
        fail "released with $PENDING_AT_RELEASE delta(s) still pending -- a later flush writes that into a ZG this node no longer owns, and a peer that has since claimed and reconciled it ends up double-counted"
fi

exec 9>&-
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null
pass "fsck clean"
ct_exit
