#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a whole-volume descriptor sweep must NOT drop this node's own BG descriptors
#
# statfs (and procfs's "info") force every Block Group descriptor fresh so a
# node can see a PEER's writes. For a BG this node OWNS that read buys
# nothing -- this node is its only writer, and cetrafs_bg_data_block_stats()
# already folds in the accrued-but-unapplied delta -- while dropping the
# cached descriptor throws away the exact block cetrafs_alloc_pick_bg()
# re-reads, for every owned BG, on EVERY single block allocation.
#
# It was harmless until v0x0004. Before it, cetrafs_bg_adjust_free_blocks()
# read-modify-wrote the descriptor in the buffer cache, so a BG being
# allocated from had a DIRTY descriptor -- and cetrafs_invalidate_block()
# refuses to drop a dirty buffer, so the sweep silently skipped exactly the
# hot ones. v0x0004 stopped dirtying it (correctly: a dirty buffer is
# flushable by background writeback at any moment, which let a stale node
# clobber a stealing peer's reconcile), leaving every descriptor clean --
# and the unchanged sweep began succeeding on the hot BGs too. On a Proxmox
# host pvestatd polls statfs every ~10s, so the allocator's cache was wiped
# mid-stream, over and over: ~200 MB/s -> ~120 MB/s on the real LUN,
# degrading further as the file grew.
#
# Discrimination: make cetrafs_bg_desc_refresh_foreign() invalidate
# unconditionally (drop its cetrafs_sb_bg_is_ours() check) and bg_desc_kept
# never leaves 0, so the first assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 2048 bgcache)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgcache)"
# Several ZGs over many small BGs: a node claims ZGs lazily, so this
# leaves some BGs owned (must be KEPT) and some not (must be REFRESHED).
ct_mkfs "$DEV" -z 4 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# This suite observes statfs THROUGH procfs info, whose foreign-BG
# sweep is rate-limited in production. Pin it off so the counters move
# on every read -- otherwise the test is blind, not passing.
ct_param_set bg_sweep_min_secs 0
PROC="$(ct_procdir "$DEV")/info"
kept()      { sed -n 's/^bg_desc_kept: //p' "$PROC"; }
refreshed() { sed -n 's/^bg_desc_refreshed: //p' "$PROC"; }

# Allocate, so this node has actually claimed a ZG and has hot descriptors.
dd if=/dev/zero of="$MNT/f" bs=1M count=16 conv=fsync status=none
sync

[ -n "$(kept)" ] || fail "procfs has no bg_desc_kept counter"

K0="$(kept)"
R0="$(refreshed)"
stat -f "$MNT" >/dev/null       # the statfs under test
K1="$(kept)"
R1="$(refreshed)"

log "bg_desc_kept $K0 -> $K1, bg_desc_refreshed $R0 -> $R1"

# THE assertion: the sweep left this node's own descriptors cached.
[ "$K1" -gt "$K0" ] ||
    fail "statfs dropped every BG descriptor: bg_desc_kept stuck at $K0 (allocator cache wiped)"

# The other direction -- we scoped the sweep, we did not disable it. A BG
# in a ZG this node has not claimed must still be forced fresh, or a peer's
# writes become invisible (the cross-node statfs bug).
[ "$R1" -gt "$R0" ] ||
    fail "statfs stopped refreshing foreign BG descriptors: bg_desc_refreshed stuck at $R0"

# And it still reports a sane volume.
stat -f -c '%b %f' "$MNT" | grep -qE '^[0-9]+ [0-9]+$' || fail "statfs output is not sane"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after the statfs sweeps"

pass "statfs refreshes foreign BG descriptors and keeps this node's own cached"

ct_exit
