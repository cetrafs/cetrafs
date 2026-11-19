#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an inode table chain longer than CETRAFS_ISEG_MAX segments is refused by the mount and by fsck
#
# A segment may hold a single inode, and the chain was bounded only by
# inodes_count (up to 4G): an image could make the mount allocate and
# walk millions of segments, and every inode-number resolution search
# them (audit 2026-11-15 F-66). The table may now have at most
# CETRAFS_ISEG_MAX (1024) segments; growfs refuses a grow that would
# add one more.
#
# An unmounted volume is given a chain of 1,100 one-inode segments
# (iseg_chain_poke), linked from the superblock:
#   1. the mount is refused, the kernel naming the cap;
#   2. fsck reports the chain as over the cap.
# With 1,000 segments (under the cap) neither names it -- the volume is
# still refused, for the segments lying in a Block Group: the message is
# the cap's and only the cap's.
#
# DISCRIMINATION: layout_iseg_uncapped=1 -- the same 1,100-segment mount
# walks the whole chain and the cap is not named.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/layout_iseg_uncapped ] || { skip "layout_iseg_uncapped is missing"; ct_exit; }
SBPOKE="$(ct_helper sb_poke)"
ICP="$(ct_helper iseg_chain_poke)"
MNT="$(ct_mnt iscc)"
ct_track mnt "$MNT"
ct_param_set layout_iseg_uncapped 0

# probe <segments> <uncapped 0|1> -> "<mount ok|refused> <kernel named yes|no> <fsck named yes|no>"
probe() {
    local img dev at mark mo=refused kn=no fn=no out
    img="$(ct_image 600 "iscc$1$2")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -s 560M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    at=$(("$("$SBPOKE" "$img" | sed -n 's/^bg_regions_start=//p')" + 2000))
    "$ICP" "$img" "$at" "$1" 1024 >/dev/null
    "$SBPOKE" "$img" inode_first_count 1024 >/dev/null
    "$SBPOKE" "$img" inode_seg_next "$at" >/dev/null
    "$SBPOKE" "$img" inodes_count $((1024 + $1)) >/dev/null
    echo "$2" >/sys/module/cetrafs/parameters/layout_iseg_uncapped
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$dev" "$MNT" 2>/dev/null; then
        mo=ok
        umount "$MNT"
    fi
    echo 0 >/sys/module/cetrafs/parameters/layout_iseg_uncapped
    dmesg_since "$mark" | grep -q "inode table chain has more than 1024 segments" && kn=yes
    out="$(ct_fsck "$dev" 2>&1)" || true
    grep -q "^ERR: inode table chain has more than 1024 segments" <<<"$out" && fn=yes
    echo "$mo $kn $fn"
}

read -r MO KN FN <<<"$(probe 1100 0)"
[ "$MO" = refused ] && [ "$KN" = yes ] && pass "1: the mount refuses 1,100 segments, naming the cap" ||
    fail "1: mount $MO, cap named by the kernel: $KN"
[ "$FN" = yes ] && pass "2: fsck reports the chain over the cap" || fail "2: fsck does not name the cap"

read -r MO KN FN <<<"$(probe 1000 0)"
[ "$KN" = no ] && [ "$FN" = no ] && pass "under the cap (1,000 segments) neither names it" ||
    fail "under the cap: kernel named it: $KN, fsck: $FN"

read -r MO KN FN <<<"$(probe 1100 1)"
[ "$KN" = no ] && pass "control: with the cap lifted the mount walks all 1,100 (cap not named, mount $MO)" ||
    fail "control: the cap was named with it lifted -- the suite cannot tell"
ct_exit
