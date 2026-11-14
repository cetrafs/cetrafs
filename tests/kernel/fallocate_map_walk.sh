#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate walks the file's extent map, not the tree, block by block
#
# fallocate looked every block of the range up in the extent tree, under
# both exclusive locks (audit 2026-11-14 FD-8): a leaf scan per block, on a
# file already in many extents. The planner now reads the map once per call
# and walks each hole to the next mapped block.
#
# Setup: a 16 MiB file with one written block every eight blocks, so the
# range is 3584 holes between 512 mapped blocks. The suite first checks that
# arrangement (a fallocate over a file that is one extent would prove
# nothing).
#
# Checks, on a fresh volume:
#   1. the planner makes no per-block tree lookup for the 4096-block range;
#   2. the written blocks read back unchanged, the new blocks read as zeroes,
#      and fsck is clean;
#   3. the control (falloc_lookup_per_block) makes at least one lookup per
#      block of the range, so the counter does see the per-block path, and
#      lays out the same extents as the fixed planner.
#
# DISCRIMINATION: falloc_lookup_per_block restores the per-block lookup; the
# counter then reaches the block count of the range.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/falloc_lookup_per_block ] || { skip "falloc_lookup_per_block is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "python3 is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt falmap)"
ct_track mnt "$MNT"
ct_param_set falloc_lookup_per_block 0
BLOCKS=4096 # 16 MiB of 4 KiB blocks

# Writes block 8k of "$1" with a pattern of k, leaving the rest holes.
arrange() {
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
for k in range(512):
    os.pwrite(fd, bytes([k & 0xff]) * 4096, k * 8 * 4096)
os.fsync(fd)
os.close(fd)' "$1"
}

# Counts the logical extents of "$1". Plain filefrag merges physically
# contiguous ones and reports 2 for this file, so the -v table is counted.
logical_extents() {
    filefrag -v "$1" | awk '/^ *[0-9]+:/ { n++ } END { print n + 0 }'
}

# Prints how many blocks of "$1" differ from what arrange() and a zeroed
# fallocate must leave there.
verify() {
    python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read(16 * 1024 * 1024)
bad = 0
for blk in range(4096):
    chunk = d[blk * 4096:(blk + 1) * 4096]
    want = bytes([(blk // 8) & 0xff]) * 4096 if blk % 8 == 0 else bytes(4096)
    if chunk != want:
        bad += 1
print(bad)' "$1"
}

# <lookup_per_block 0|1> -> "<extents_before> <lookups> <extents_after> <verify_bad> <fsck ok|bad>"
probe() {
    local img dev c0 c1 ext0 ext bad ok
    img="$(ct_image 560 "falm$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    arrange "$MNT/p"
    sync
    echo "$1" >$P/falloc_lookup_per_block
    counter() { sed -n 's/^fallocate_tree_lookups: //p' "$(ct_procdir "$dev")/info"; }
    ext0="$(logical_extents "$MNT/p")"
    c0="$(counter)"
    fallocate -l 16M "$MNT/p"
    c1="$(counter)"
    echo 0 >$P/falloc_lookup_per_block
    ext="$(logical_extents "$MNT/p")"
    bad="$(verify "$MNT/p")"
    sync
    ct_umount "$MNT"
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$ext0 $((c1 - c0)) $ext $bad $ok"
}

read -r EXT0 LOOK EXT BAD OK <<<"$(probe 0)"
log "setup: $EXT0 extent(s) before the fallocate; fixed: $LOOK tree lookup(s), $EXT extent(s)"
[ "$EXT0" -ge 500 ] && pass "setup: the range arrived as 500+ mapped extents with holes between them" ||
    fail "setup: the file was not arranged as holes between mapped blocks ($EXT0 extents)"
[ "$LOOK" -le 16 ] && pass "1: the planner makes no per-block tree lookup ($LOOK for $BLOCKS blocks)" ||
    fail "1: $LOOK tree lookups for $BLOCKS blocks -- one per block is still paid"
[ "$BAD" = 0 ] && pass "2: written blocks read back, new blocks read as zeroes" ||
    fail "2: $BAD block(s) read back wrong after the fallocate"
[ "$OK" = ok ] && pass "2: fsck clean after the fallocate over a mapped file" || fail "2: fsck is not clean"

read -r CEXT0 CLOOK CEXT CBAD COK <<<"$(probe 1)"
log "control (per-block lookup): $CLOOK tree lookup(s), $CEXT extent(s)"
[ "$CLOOK" -ge "$BLOCKS" ] && pass "control: the per-block path looks up every block -- the suite discriminates" ||
    fail "control: $CLOOK lookups for $BLOCKS blocks -- the counter does not see the per-block path"
[ "$CEXT" = "$EXT" ] && pass "3: both planners lay out the same extents ($EXT)" ||
    fail "3: the map planner laid out $EXT extents, the per-block planner $CEXT"
[ "$CBAD" = 0 ] && [ "$COK" = ok ] && pass "control: same data and fsck" || fail "control: data or fsck differs"
ct_exit
