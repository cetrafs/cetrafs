#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub bounds its reference set by the device's inode table, not by the one this node last caught up with
#
# A peer's grow appends an inode segment, and this node learns of it on
# its next heartbeat. The scrub built its reference set from inodes 1 ..
# cetrafs_sb_inodes() -- this node's count -- so a file in the new
# segment protected nothing, and its blocks read as leaked: the deciding
# pass freed live data (format batch review H1; rule 6: an OLDER layout
# means fewer references, the destructive direction).
#
# One host is one node, so the peer is played by this node itself:
# grow_skip_local_publish commits the grow and leaves this node's layout
# behind, and layout_refresh_hb_off keeps the heartbeat from catching
# up. The peer's file is planted on the backing file: a regular record
# at a number in the new segment, its bit set in that segment's bitmap,
# its extent naming leaked blocks A of Block Group 0. Leaked blocks B
# are named by nothing.
#
#   setup: the scrub reclaims B -- its deciding pass ran;
#   1. A is still allocated.
#
# DISCRIMINATION: without the layout refresh in scrub_build_refset(), A
# is reclaimed with B.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAK="$(ct_helper data_leak_poke)"
IBP="$(ct_helper inode_block_poke)"
EPP="$(ct_helper extent_phys_poke)"
BMP="$(ct_helper bmap_poke)"
BGPOKE="$(ct_helper bg_poke)"

IMG="$(ct_big_image 1200 scrubgrow)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubgrow)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
A=6000 B=7000 # data-region offsets in BG 0, 4 blocks each
"$LEAK" "$DEV" 0 "$A" 4 >/dev/null
"$LEAK" "$DEV" 0 "$B" 4 >/dev/null
read -r ST OBM ODR <<<"$("$BGPOKE" "$DEV" 0 --dump | sed -n 's/.*start_block=\([0-9]*\).*off_data_bmap=\([0-9]*\).*off_data_region=\([0-9]*\).*/\1 \2 \3/p')"
[ -n "$ODR" ] || { fail "setup: cannot read Block Group 0's layout"; ct_exit; }
bits() { blockdev --flushbufs "$DEV"; "$BMP" "$DEV" "$((ST + OBM))" count "$1" 4; }

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set layout_refresh_hb_off 1
ct_param_set grow_skip_local_publish 1
OUT="$(ct_growfs "$DEV" -s 1100M -N 1300 2>&1)" || { fail "setup: growfs: $OUT"; ct_exit; }
ct_param_set grow_skip_local_publish 0
[ "$(info inodes_count)" = 1024 ] ||
    { fail "setup: this node already knows $(info inodes_count) inodes -- it is not behind the grow"; ct_exit; }

# The peer's file, in the segment this node has not seen.
N=1200
"$IBP" "$IMG" plantrec "$N" 100644 2>/dev/null
"$IBP" "$IMG" nlink "$N" 1 >/dev/null 2>&1
"$IBP" "$IMG" ehset "$N" entries 1 >/dev/null 2>&1
"$IBP" "$IMG" extset "$N" 0 block 0 >/dev/null 2>&1
"$IBP" "$IMG" extset "$N" 0 len 4 >/dev/null 2>&1
"$EPP" "$IMG" "$N" "$((ST + ODR + A))" >/dev/null 2>&1
"$BMP" "$IMG" ino "$N" 1
[ "$("$BMP" "$IMG" ino "$N")" = 1 ] && [ "$(bits "$A")" = 4 ] && [ "$(bits "$B")" = 4 ] ||
    { fail "setup: the planted file or the leaks are not in place"; ct_exit; }

C0="$(info scrub_cycles)"
ct_param_set scrub 1
wait_for 60 '[ "$(bits "$B")" = 0 ] && [ "$(info scrub_cycles)" -ge $((C0 + 2)) ]' ||
    { fail "setup: the scrub did not reclaim the unreferenced leak B in time ($(bits "$B") of 4 still set)"; ct_exit; }
ct_param_set scrub 0
pass "setup: the scrub's deciding pass ran and reclaimed B"

[ "$(bits "$A")" = 4 ] && pass "1: the new segment's file kept its blocks" ||
    fail "1: $((4 - $(bits "$A"))) of the 4 blocks of a file in the new segment were reclaimed as leaked"
ct_param_set layout_refresh_hb_off 0
ct_umount "$MNT"
ct_exit
