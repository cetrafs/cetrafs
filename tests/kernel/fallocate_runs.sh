#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate claims runs of blocks, not one allocator call per block
#
# fallocate(ALLOCATE) took one allocator call per block, under both
# exclusive locks (audit 2026-11-14 FD-8): a 16 MiB range was 4096 bitmap
# searches. It now claims the run of blocks after each new block in one
# call (cetrafs_alloc_run_after()) and gives back what it did not use.
#
# Checks, on a fresh volume:
#   1. the allocator-call counter for a 16 MiB fallocate is far below one
#      call per block, and the file is one extent of the right size;
#   2. a fallocate across an already-written block (a run cannot cross it)
#      and a partial range leave the volume fsck-clean: no leaked run blocks.
#
# DISCRIMINATION: falloc_run_off restores one allocator call per block; the
# counter then reaches at least two calls per block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/falloc_run_off ] || { skip "falloc_run_off is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt falr)"
ct_track mnt "$MNT"
ct_param_set falloc_run_off 0

# <run_off 0|1> -> "<calls> <blocks> <extents> <bytes>"
probe() {
    local img dev c0 c1 ext
    img="$(ct_image 560 "falr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    echo "$1" >$P/falloc_run_off
    counter() { sed -n 's/^fallocate_alloc_calls: //p' "$(ct_procdir "$dev")/info"; }
    c0="$(counter)"
    fallocate -l 16M "$MNT/f"
    c1="$(counter)"
    echo 0 >$P/falloc_run_off
    ext="$(filefrag "$MNT/f" | awk '{print $2}')"
    blocks="$(stat -c %b "$MNT/f")"
    ct_umount "$MNT"
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$((c1 - c0)) 4096 $ext $blocks $ok"
}

read -r CALLS BLOCKS EXT _ OK <<<"$(probe 0)"
log "fixed: $CALLS allocator call(s) for $BLOCKS blocks, $EXT extent(s)"
[ "$CALLS" -lt $((BLOCKS / 8)) ] && pass "1: a 16 MiB fallocate makes $CALLS allocator calls, not one per block" ||
    fail "1: $CALLS allocator calls for $BLOCKS blocks -- still one per block"
[ "$OK" = ok ] && pass "fixed: fsck clean after the run allocation" || fail "fixed: fsck is not clean"
read -r CCALLS _ CEXT _ COK <<<"$(probe 1)"
log "control (one block per call): $CCALLS allocator call(s), $CEXT extent(s)"
[ "$CCALLS" -ge $((BLOCKS * 2)) ] && pass "control: the per-block path makes at least two calls a block -- the suite discriminates" ||
    fail "control: $CCALLS calls -- the counter does not see the per-block path"

# 2. a written block inside the range: a run cannot cross it, and the
# blocks claimed beyond it are given back.
img="$(ct_image 560 falrh)"
dev="$(ct_loop "$img")"
ct_mkfs_small "$dev" >/dev/null
ct_mount "$dev" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/g" bs=4096 count=1 seek=100 conv=fsync status=none
fallocate -l 4M "$MNT/g"
sync
ct_umount "$MNT"
ct_fsck "$dev" >/dev/null 2>&1 && pass "2: a fallocate across a written block leaves the volume fsck-clean" ||
    fail "2: fsck after a fallocate across a written block: $(ct_fsck "$dev" 2>&1 | grep -i err | head -2)"
ct_exit
