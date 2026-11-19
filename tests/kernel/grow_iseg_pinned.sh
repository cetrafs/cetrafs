#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a layout refresh only appends inode table segments: one that moved, or a new one inside the old Block Groups, is refused
#
# A node learns a peer's grow by re-reading the superblock and walking
# its chains. The inode table chain was walked as found: a CRC-valid
# superblock or chain that MOVED a segment this node resolves numbers
# through was adopted silently, and so was a new segment lying inside a
# Block Group that already existed -- every later record write and
# bitmap CAS then aimed at the new address, over live data (audit
# 2026-11-15 F-63). The Block Group chain had both checks; the inode
# chain now has them too (cetrafs_layout_isegs_extend()).
#
# One node: a live grow adds an inode segment S, which the node adopts.
# A peer's superblock is then forged on the device, layout_gen bumped:
#   A. S copied, byte for byte, over a live file's blocks at X, and
#      inode_seg_next pointed at the copy -- segment 1 "moved";
#   B. the copy at X renumbered as the NEXT segment (first id 1300, zero-based),
#      linked from S, inodes_count raised to match -- a grow whose new
#      segment lies inside the old Block Groups.
# Each: the heartbeat's refresh refuses it (layout_refresh_refused
# moves, dmesg names it) and the node keeps its layout_gen.
#
# DISCRIMINATION: layout_iseg_unpinned=1 adopts both (layout_gen moves).
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/layout_iseg_unpinned ] || { skip "layout_iseg_unpinned is missing"; ct_exit; }
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }
SBPOKE="$(ct_helper sb_poke)"
SEGPOKE="$(ct_helper seg_poke)"
ct_param_set hb_interval_secs 2
ct_param_set layout_iseg_unpinned 0

# probe <A|B> <unpinned 0|1> -> "<adopted yes|no> <refused yes|no> <named yes|no>"
probe() {
    local img dev mnt S X gen r0 i adopted=no refused=no named=no mark
    img="$(ct_big_image 1100 "gisp$1$2")"
    dev="$(ct_loop "$img")"
    mnt="$(ct_mnt "gisp$1$2")"
    ct_track mnt "$mnt"
    info() { sed -n "s/^$1: //p" "$(ct_procdir "$dev")/info"; }
    ct_mkfs "$dev" -s 600M -b 512 -z 1 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$mnt"
    ct_growfs "$dev" -s 1100M -N 1300 >/dev/null 2>&1 || { echo "setup-grow"; return; }
    [ "$(info inodes_count)" = 1300 ] || { echo "setup-notadopted"; return; }
    dd if=/dev/zero of="$mnt/pad" bs=4096 count=400 conv=fsync status=none
    [ "$(filefrag "$mnt/pad" | grep -o '[0-9]* extent' | cut -d' ' -f1)" = 1 ] || { echo "setup-padfrag"; return; }
    X=$(($(filefrag -v -b4096 "$mnt/pad" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }') + 1))
    S="$("$SBPOKE" "$img" | sed -n 's/^inode_seg_next=//p')"
    gen="$("$SBPOKE" "$img" | sed -n 's/^layout_gen=//p')"
    [ -n "$S" ] && [ "$S" != 0 ] && [ "$(info layout_gen)" = "$gen" ] || { echo "setup-noseg"; return; }
    ct_param_set layout_iseg_unpinned "$2"
    r0="$(info layout_refresh_refused)"
    mark="$(dmesg_mark)"
    SEG_POKE_CHAIN=inode "$SEGPOKE" "$img" copyto "$X" >/dev/null
    "$SBPOKE" "$img" inode_seg_next "$X" >/dev/null
    if [ "$1" = B ]; then
        SEG_POKE_CHAIN=inode "$SEGPOKE" "$img" firstid 1300 >/dev/null # the head is the copy now
        "$SBPOKE" "$img" inode_seg_next "$S" >/dev/null
        SEG_POKE_CHAIN=inode "$SEGPOKE" "$img" dangle "$X" >/dev/null # S -> X
        "$SBPOKE" "$img" inodes_count $((1300 + 276)) >/dev/null
    fi
    "$SBPOKE" "$img" layout_gen $((gen + 1)) >/dev/null
    for i in $(seq 1 20); do
        [ "$(info layout_gen)" = $((gen + 1)) ] && { adopted=yes; break; }
        [ "$(info layout_refresh_refused)" -gt "$r0" ] && { refused=yes; break; }
        sleep 1
    done
    dmesg_since "$mark" | grep -q "inode table: segment 1 moved or changed size\|inode table segment at $X lies inside the Block Groups" &&
        named=yes
    [ "$named" = yes ] || dmesg_since "$mark" | grep -i "refus\|segment\|inode table" | head -4 >&2
    ct_param_set layout_iseg_unpinned 0
    # Put the chain back (the bumped layout_gen stays, and is adopted).
    "$SBPOKE" "$img" inode_seg_next "$S" >/dev/null
    "$SBPOKE" "$img" inodes_count 1300 >/dev/null
    SEG_POKE_CHAIN=inode "$SEGPOKE" "$img" dangle 0 >/dev/null 2>&1 || true
    "$SBPOKE" "$img" layout_gen $((gen + 2)) >/dev/null
    umount "$mnt" 2>/dev/null || umount -l "$mnt"
    echo "$adopted $refused $named"
}

for C in A B; do
    read -r AD RF NM <<<"$(probe "$C" 0)"
    case "$AD" in setup-*) fail "$C setup: $AD"; continue ;; esac
    [ "$AD" = no ] && [ "$RF" = yes ] && [ "$NM" = yes ] &&
        pass "$C: the refresh refused the forged chain and named it; the node kept its layout" ||
        fail "$C: adopted=$AD refused=$RF named=$NM"
    read -r AD RF NM <<<"$(probe "$C" 1)"
    case "$AD" in setup-*) fail "$C control setup: $AD"; continue ;; esac
    [ "$AD" = yes ] && pass "$C control: without the check the forged chain is adopted -- the suite discriminates" ||
        fail "$C control: adopted=$AD refused=$RF -- something else refuses it; the suite cannot tell"
done
ct_exit
