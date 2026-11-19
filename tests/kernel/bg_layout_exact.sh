#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount refuses a Block Group descriptor whose layout is in bounds but not the one its length gives
#
# A descriptor's offsets aim I/O: the bitmap at start + off_data_bmap,
# the data at start + off_data_region. The kernel checked them only for
# bounds; fsck requires exactly cetrafs_calc_bg_layout()'s ("layout
# mismatch"). A bitmap moved by a block, or a data count one short, both
# in bounds, mounted -- the first reads the group's allocations off by
# 32768 bits -- while fsck refused the volume (audit 2026-11-15 BL-33).
#
# Staged with bg_poke --geom (the checksum restamped): BG 0's
# data_block_count one short; and, where the alignment leaves room
# below it, its off_data_bmap one lower.
#   1. each is refused at mount;
#   2. fsck refuses each (the two agree);
#   3. the image with the field restored mounts.
#
# DISCRIMINATION: bg_layout_any=1 -- the same images mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bg_layout_any ] || { skip "bg_layout_any is missing"; ct_exit; }
BG_POKE="$(ct_helper bg_poke)"
IMG="$(ct_image 1200 bglay)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bglay)"
ct_track mnt "$MNT"
ct_param_set bg_layout_any 0
ct_mkfs_small "$DEV" >/dev/null
geom() { "$BG_POKE" "$IMG" 0 --dump | sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }

# <field> <value> <original>
check() {
    local field="$1" val="$2" orig="$3" mark o
    "$BG_POKE" "$IMG" 0 --geom="$field" "$val" >/dev/null
    blockdev --flushbufs "$DEV"
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        fail "1: BG 0 with $field $val (computed $orig) mounted"
        umount "$MNT"
    else
        dmesg_since "$mark" | grep -q "Block Group 0's descriptor does not verify" &&
            pass "1: BG 0 with $field $val (computed $orig) is refused at mount" ||
            fail "1: refused, but not for the descriptor: $(dmesg_since "$mark" | grep -i cetrafs | tail -2)"
    fi
    o="$(ct_fsck "$DEV" 2>&1 || true)"
    grep -q "BG0 layout mismatch" <<<"$o" && pass "2: fsck refuses it too" || fail "2: fsck did not refuse $field $val"
    echo 1 >/sys/module/cetrafs/parameters/bg_layout_any
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        pass "control: accepting any in-bounds layout, the same image mounts"
        umount "$MNT"
    else
        fail "control: the image does not mount even with any layout accepted -- the refusal proves nothing"
    fi
    echo 0 >/sys/module/cetrafs/parameters/bg_layout_any
    "$BG_POKE" "$IMG" 0 --geom="$field" "$orig" >/dev/null
    blockdev --flushbufs "$DEV"
    ct_mount "$DEV" "$MNT" && pass "3: restored, it mounts" || fail "3: the restored image does not mount"
    ct_umount "$MNT"
}

CNT="$(geom data_block_count)" BM="$(geom off_data_bmap)"
[ -n "$CNT" ] && [ "$CNT" -gt 1 ] && [ -n "$BM" ] || { fail "setup: no BG 0 geometry read ($CNT, $BM)"; ct_exit; }
check data_block_count $((CNT - 1)) "$CNT"
if [ "$BM" -gt 1 ]; then
    check off_data_bmap $((BM - 1)) "$BM"
else
    log "off_data_bmap is 1: no room below it on this layout, that case is not staged"
fi
ct_exit
