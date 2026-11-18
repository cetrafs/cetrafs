#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# each node takes inode numbers from its own region, and a contended region is passed over, never EBUSY
#
# Every node started its inode-bitmap walk at region 0, so every create
# in the cluster swapped the same 512 bytes; a node that lost that swap
# 16 times running returned EBUSY from creat(2), an errno it does not
# define (audit 2026-11-14 M-4). The walk now starts at a region chosen
# by node id and wraps, and a contended region is passed over.
#
# One host, two TEST ONLY knobs: ibmap_start_as_node makes the walk start
# where another node id would, ibmap_busy_regions makes chosen regions
# report the contention a lost swap does. 65536 inodes, 4 nodes: 17
# regions of 3968 numbers (a 512-byte bitmap sector less its trailer),
# node 2 starting at region 17 * 2 / 4 = 8.
#
#   A. as node 2, a create takes a number in region 8 (31745..35712).
#   B. region 0 contended: a create takes a number in region 1 and the
#      skip is counted.
#   C. every region contended: the create fails EIO within seconds --
#      not EBUSY, and not a hang.
#   fsck clean.
#
# DISCRIMINATION: ibmap_spread_off=1 (the old walk): A's number is in
# region 0, B's create fails EBUSY.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in ibmap_start_as_node ibmap_busy_regions ibmap_spread_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set ibmap_start_as_node -1
ct_param_set ibmap_busy_regions 0
ct_param_set ibmap_spread_off 0
IMG="$(ct_image 1200 ibspread)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ibspread)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 65536 -f >/dev/null
ct_mount "$DEV" "$MNT"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <name> -> "ino=<n>" or "err=<message>"
create() {
    local err
    if err="$(touch "$MNT/$1" 2>&1)"; then
        echo "ino=$(stat -c %i "$MNT/$1")"
    else
        echo "err=${err##*: }"
    fi
}
REGION=3968 # CETRAFS_BMAP_SECTOR_BITS
NREGIONS=$(((65536 + REGION - 1) / REGION))
region_of() { echo $((($1 - 1) / REGION)); }

# A. the start region
echo 2 >$P/ibmap_start_as_node
A="$(create a)"
echo 1 >$P/ibmap_spread_off
A_CTL="$(create a_ctl)"
echo 0 >$P/ibmap_spread_off
echo -1 >$P/ibmap_start_as_node
log "A: as node 2: $A; control: $A_CTL"
case "$A" in
ino=*) [ "$(region_of "${A#ino=}")" = 8 ] && pass "A: node 2 takes its number from region 8 (${A#ino=})" ||
    fail "A: node 2's number ${A#ino=} is in region $(region_of "${A#ino=}"), not 8" ;;
*) fail "A: the create failed: $A" ;;
esac
case "$A_CTL" in
ino=*) [ "$(region_of "${A_CTL#ino=}")" = 0 ] && pass "A control: the old walk starts every node at region 0" ||
    fail "A control: the old walk's number ${A_CTL#ino=} is not in region 0" ;;
*) fail "A control: the create failed: $A_CTL" ;;
esac

# B. a contended region is passed over
s0="$(info ibmap_busy_skips)"
echo 1 >$P/ibmap_busy_regions
B="$(create b)"
s1="$(info ibmap_busy_skips)"
echo 1 >$P/ibmap_spread_off
B_CTL="$(create b_ctl)"
echo 0 >$P/ibmap_spread_off
echo 0 >$P/ibmap_busy_regions
log "B: region 0 contended: $B (skips $s0 -> $s1); control: $B_CTL"
case "$B" in
ino=*) [ "$(region_of "${B#ino=}")" = 1 ] && [ "$s1" -gt "$s0" ] &&
    pass "B: region 0 contended, the create takes region 1 (${B#ino=}) and counts the skip" ||
    fail "B: number ${B#ino=} in region $(region_of "${B#ino=}"), skips $s0 -> $s1" ;;
*) fail "B: the create failed with region 0 contended: $B" ;;
esac
case "$B_CTL" in
"err=Device or resource busy") pass "B control: the old walk fails the create EBUSY" ;;
*) fail "B control: the old walk did not fail EBUSY ($B_CTL) -- the knob does not reach the contended path" ;;
esac

# C. every region contended
echo $(((1 << NREGIONS) - 1)) >$P/ibmap_busy_regions
t0=$SECONDS
C="$(create c)"
secs=$((SECONDS - t0))
echo 0 >$P/ibmap_busy_regions
log "C: every region contended: $C in ${secs}s"
[ "$C" = "err=Input/output error" ] && [ "$secs" -le 10 ] &&
    pass "C: every region contended, the create fails EIO in ${secs}s" ||
    fail "C: every region contended: $C after ${secs}s (expected EIO within 10 s)"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck reports damage: $(ct_fsck "$DEV" 2>&1 | grep ERR | head -3)"
ct_exit
