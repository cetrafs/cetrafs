#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# speculative run allocation: one allocator call per RUN, not per block
#
# __block_write_begin() hands cetrafs_get_block() exactly one block at a
# time, so every 4 KiB of a buffered write used to be its own allocator
# call. Measured on the deployment LUN: 588,415 calls for a 2.24 GiB
# qemu-img convert, with map_calls at zero -- every one an allocation.
#
# A reservation claims a run once and serves the following blocks from
# it. The blocks in that run are SET IN THE BITMAP and referenced by no
# extent, so an unused remainder must be given back on release/evict or
# it leaks -- which is what the free-space assertions below are for, and
# why fsck runs at the end.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 runresv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt runresv)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
picks() { sed -n 's/^bg_pick_cursor: //p' "$PROC"; }
freeb() { sed -n 's/^free_data_blocks: //p' "$PROC"; }

# 32 MiB buffered == 8192 blocks == 8192 get_block calls.
P0="$(picks)"
dd if=/dev/zero of="$MNT/big" bs=1M count=32 conv=fsync status=none
sync
P1="$(picks)"
CALLS=$((P1 - P0))
log "8192 blocks written: $CALLS allocator calls"

[ "$CALLS" -gt 0 ] || fail "no allocator calls at all -- the test observed nothing"

# THE assertion: far fewer calls than blocks. With a 256-block run it
# should be ~32; allow generous slack, the point is O(blocks/run).
# 8192 blocks at a 256-block run is 32 calls. 256 still proves runs work
# (8x slack for short runs on a busy bitmap) while sitting 32x below the
# 8192 that one-call-per-block produces -- measured: 8192 with
# alloc_run_blocks=0, 32 with it at 256.
RUNSZ="$(cat /sys/module/cetrafs/parameters/alloc_run_blocks 2>/dev/null || echo 0)"
[ "$RUNSZ" -gt 0 ] || fail "alloc_run_blocks=$RUNSZ -- the feature is off, this test would prove nothing"
log "alloc_run_blocks=$RUNSZ"
[ "$CALLS" -lt 256 ] ||
    fail "$CALLS allocator calls for 8192 blocks (run size $RUNSZ) -- runs are barely working"

# No leak: free space must reflect the data, not the data plus an
# abandoned run. Close the file first so the reservation is returned.
FREE_AFTER="$(freeb)"
rm -f "$MNT/big"
sync
sleep 1
FREE_END="$(freeb)"
log "free blocks after delete: $FREE_END"

# Everything the file used must come back. A leaked reservation shows up
# as permanently missing blocks.
FREE_START=$(( FREE_AFTER + 8192 ))
MISSING=$(( FREE_START - FREE_END ))
[ "$MISSING" -le 8 ] ||
    fail "$MISSING blocks did not come back after delete -- a reservation leaked"

# Data must be correct, not just cheap.
dd if=/dev/zero of="$MNT/v" bs=1M count=8 conv=fsync status=none
cmp -s <(dd if=/dev/zero bs=1M count=8 status=none) "$MNT/v" || fail "file read back wrong"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults -- leaked or double-allocated blocks"

pass "allocation runs collapse per-block allocator calls and leak nothing"

ct_exit
