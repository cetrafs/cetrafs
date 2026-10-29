#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a writeback publish must never be lost between a record read and its shadow overlay
#
# THE RACE THIS PINS DOWN (found as "leaked blocks" by a two-writer fill
# with auto-defrag -- which turned out to be silent DATA LOSS, a
# 223-block extent missing from the middle of a written file): the hot
# write path read the inode record and overlaid the in-core shadow as
# two separate steps. VFS writeback's publisher (which takes no
# inode_lock) could land its CAS *and* clear the shadow's dirty flag in
# between -- the reader then held a record from BEFORE the publish and a
# shadow that no longer carried it, rebuilt the extent tree from that
# lagging record, and staged it over everything published. Every extent
# staged since the previous publish vanished: bitmap bits set, no
# referrer (fsck "leaked"), file reads back a hole.
#
# Defrag merely widened the window with its synchronous I/O storm; the
# race is in the core write path and is wider still on real hardware,
# where the publish is a full device round trip.
#
# fd_overlay_stall_ms holds that exact window open (between the record
# read and the overlay check) so one writer plus a stream of syncs hits
# it deterministically. The fix samples the dirty flag BEFORE the read
# and re-reads when a publish's clear lands inside the window; with the
# fix reverted this suite fails its content and fsck assertions
# (verified during review).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

if [ ! -w /sys/module/cetrafs/parameters/fd_overlay_stall_ms ]; then
    skip "fd_overlay_stall_ms unavailable -- cannot hold the race window open"
    ct_exit
fi

DEV="$(ct_dev 600 torn)"
MNT="$(ct_mnt torn)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_shadow 1

SRC="$(ct_tmp torn-src)"
dd if=/dev/urandom of="$SRC" bs=1M count=4 status=none
SUM="$(sha256sum "$SRC" | cut -d' ' -f1)"

log "writing 4 MiB with the read-to-overlay window held open and publishes streaming"
ct_param_set fd_overlay_stall_ms 10

# A stream of syncs makes the VFS publish the inode repeatedly WHILE the
# writer's get_block sits inside the stalled window.
( while [ -f "$MNT/.syncing" ]; do sync -f "$MNT" 2>/dev/null || sync; done ) &
SYNCER=$!
: >"$MNT/.syncing"

# Small appends so every block goes through get_block while syncs land.
dd if="$SRC" of="$MNT/victim" bs=64k oflag=append conv=notrunc status=none
sync
rm -f "$MNT/.syncing"; wait $SYNCER 2>/dev/null || true
ct_param_set fd_overlay_stall_ms 0

GOT="$(sha256sum "$MNT/victim" | cut -d' ' -f1)"
[ "$GOT" = "$SUM" ] && pass "content intact while cached" ||
    fail "content wrong even before the cache drop"

echo 3 >/proc/sys/vm/drop_caches
GOT="$(sha256sum "$MNT/victim" | cut -d' ' -f1)"
[ "$GOT" = "$SUM" ] && pass "content intact from disk -- no extent was lost to a mid-read publish" ||
    fail "the file reads back WRONG from disk: an extent staged during a publish was lost"

ct_umount "$MNT"
if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck: no leaked blocks, no overlap"
else
    fail "fsck found damage: $(ct_fsck "$DEV" 2>&1 | grep -m2 -E 'ERR|WARN')"
fi

ct_exit
