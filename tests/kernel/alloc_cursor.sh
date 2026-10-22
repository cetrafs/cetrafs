#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# block allocation must not rescan every owned BG descriptor per block
#
# cetrafs_alloc_pick_bg() is called ONCE PER 4 KiB BLOCK a write allocates,
# and its scan reads every owned BG's descriptor -- each costing a CRC32C
# over a full 4096-byte block. At a few tens of owned BGs that is a core's
# worth of CRC per second of streaming write, and it GROWS as a filling
# node claims more Zone Groups, so throughput decays as a large file
# progresses. The allocation cursor makes the steady state one descriptor
# read instead of N.
#
# Discrimination: delete the cursor fast path from cetrafs_alloc_pick_bg()
# and every allocation takes the scan, so bg_pick_cursor stays 0 and
# bg_pick_scan rises once per block -- both assertions below fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 2048 alloccur)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt alloccur)"
ct_mkfs "$DEV" -z 4 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
cursor() { sed -n 's/^bg_pick_cursor: //p' "$PROC"; }
scans()  { sed -n 's/^bg_pick_scan: //p' "$PROC"; }

[ -n "$(cursor)" ] || fail "procfs has no bg_pick_cursor counter"

C0="$(cursor)"; S0="$(scans)"
# 64 MiB == 16384 blocks, so 16384 pick_bg calls: far more than the
# handful of scans a steady sequential write may legitimately need.
dd if=/dev/zero of="$MNT/big" bs=1M count=64 conv=fsync status=none
sync
C1="$(cursor)"; S1="$(scans)"

DC=$((C1 - C0)); DS=$((S1 - S0))
log "pick_bg during a 64 MiB write: $DC cursor hits, $DS full scans"

[ "$DC" -gt 0 ] ||
    fail "allocation never used the cursor: every block rescanned every owned BG descriptor"

# The real property: the scan runs only when the cursor has to be
# re-seated (a BG filled up), NOT per block. For a 64 MiB write into a
# fresh BG that is one or two. The old bound was DC/100 + 50, which for
# 16384 allocations permitted 213 scans -- it scaled WITH the block
# count, so it would have passed against code still scanning every
# hundredth block. Measured here: 0.
[ "$DS" -le 8 ] ||
    fail "pick_bg ran $DS full owned-BG scans for $DC allocations -- the per-block scan is back"

# The cursor must not cost correctness: the data must read back intact
# and the allocator's accounting must still close.
cmp -s <(dd if=/dev/zero bs=1M count=64 status=none) "$MNT/big" ||
    fail "the file read back wrong"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after cursor-driven allocation"

pass "pick_bg answers from the allocation cursor instead of rescanning every BG"

ct_exit
