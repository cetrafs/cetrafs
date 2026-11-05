#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a preallocation stops where the extent tree is full, keeping what fits
#
# cetrafs_do_allocate() planned one extent per discontiguous block for the
# whole range and only cetrafs_tree_build() -- after every block had been
# allocated and recorded -- refused past the tree's capacity, throwing all
# of it away: on a fragmented volume a large fallocate spent its time and
# memory on a preallocation that could never be published (audit
# 2026-11-05, class 13/12). The plan now stops at the capacity: what fits
# is published and the call reports ENOSPC, as a stop part-way does.
#
# The real capacity (~258k extents) is out of reach of a loop device;
# tree_extent_cap lowers it for planner and builder alike. A file with 40
# one-block extents (every other block written) and a cap of 50: an
# fallocate over its holes may add exactly 10 single-block extents.
#
# DISCRIMINATION: proven 2026-11-05 with the planner's stop removed (the
# builder's refusal kept): the call fails ENOSPC having published nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/tree_extent_cap ] || { skip "tree_extent_cap is missing"; ct_exit; }
command -v filefrag >/dev/null || { skip "needs filefrag (e2fsprogs)"; ct_exit; }

DEV="$(ct_dev 560 ftfull)"
MNT="$(ct_mnt ftfull)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
F="$MNT/frag"
for i in $(seq 0 2 78); do
    dd if=/dev/urandom of="$F" bs=4096 count=1 seek="$i" conv=notrunc,fsync status=none
done
# fiemap's entries (filefrag's summary line merges physically contiguous ones)
extents() { filefrag -v "$F" | grep -cE '^ *[0-9]+:' || true; }
E0="$(extents)"
[ "$E0" = 40 ] || { fail "setup: the file has $E0 extents, not 40"; ct_exit; }
B0="$(stat -c %b "$F")"
pass "setup: 40 one-block extents ($B0 sectors)"

ct_param_set tree_extent_cap 50
RC=0
ERR="$(fallocate -n -o 0 -l $((400 * 4096)) "$F" 2>&1)" || RC=$?
ct_param_set tree_extent_cap 0
log "fallocate: rc=$RC $ERR"
[ "$RC" != 0 ] && grep -qi "no space" <<<"$ERR" && pass "the preallocation reports ENOSPC at the tree's capacity" ||
    fail "the preallocation past the tree's capacity returned rc=$RC: $ERR"
E1="$(extents)"
B1="$(stat -c %b "$F")"
[ "$E1" = 50 ] && pass "and published what fits: the tree is full at 50 extents" ||
    fail "after the stop the file has $E1 extents, not the 50 that fit"
[ "$((B1 - B0))" = 80 ] && pass "exactly 10 blocks were added ($B0 -> $B1 sectors)" ||
    fail "the file went from $B0 to $B1 sectors, not +80 (10 blocks)"

ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && ! grep -qE "leaked" <<<"$fo" && pass "fsck clean, nothing leaked by the stop" ||
    fail "fsck rc=$frc: $(grep -E '^ERR|leaked' <<<"$fo" | head -2)"
ct_exit
