#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an extent aimed at a Block Group's bitmap is refused, not written through
#
# The per-block address check stopped at the box [bg_regions_start,
# bg_data_end), and every group's header and data bitmap sit inside that
# box, between two data regions. An extent naming a bitmap therefore
# mapped: a write(2) to the file laid file bytes over the bitmap, every
# bit it cleared marked a live block of some other file free, and the
# allocator handed those out -- two files on one block (audit 2026-11-14
# M-40). The check now asks that a run lie inside ONE group's data
# region, from geometry the mount keeps in memory, as fsck does.
#
# A file's one-block extent is redirected (CRC restamped) to the last
# Block Group's bitmap block; the file is read and written:
#   1. the bitmap block is byte-identical afterwards;
#   2. the read did not serve the bitmap;
#   3. the kernel logged the refusal; fsck still names the extent.
#
# DISCRIMINATION: lba_bg_check_off=1 (the box alone, as before): the
# write lands on the bitmap.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lba_bg_check_off ] || { skip "lba_bg_check_off is missing"; ct_exit; }
PPOKE="$(ct_helper extent_phys_poke)"
MNT="$(ct_mnt eab)"
ct_track mnt "$MNT"
ct_param_set lba_bg_check_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
h() { dd if="$1" bs=4096 skip="$2" count=1 status=none | sha256sum | cut -d' ' -f1; }

# <tag> <check_off 0|1> -> RES
round() {
    local img dev ino poked tgt before after rd mark out
    img="$(ct_image 1200 "eab$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    printf 'victim' >"$MNT/victim"
    sync
    ino="$(stat -c %i "$MNT/victim")"
    ct_umount "$MNT"
    poked="$("$PPOKE" "$img" "$ino" bg_bitmap_last)" || { fail "setup: the poke refused: $poked"; ct_exit; }
    tgt="$(sed -n 's/.*-> \([0-9][0-9]*\) .*/\1/p' <<<"$poked")"
    [ -n "$tgt" ] || { fail "setup: no target in: $poked"; ct_exit; }
    blockdev --flushbufs "$dev"
    before="$(h "$img" "$tgt")"
    echo "$2" >/sys/module/cetrafs/parameters/lba_bg_check_off
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    rd="$(dd if="$MNT/victim" bs=4096 count=1 status=none 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
    dd if=/dev/urandom of="$MNT/victim" bs=4096 count=1 conv=notrunc status=none 2>/dev/null || true
    sync || true
    ct_umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/lba_bg_check_off
    after="$(h "$img" "$tgt")"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    RES="tgt=$tgt same=$([ "$before" = "$after" ] && echo 1 || echo 0)"
    RES="$RES served=$([ "$rd" = "$before" ] && echo 1 || echo 0)"
    RES="$RES logged=$(dmesg_since "$mark" | grep -c 'is not a data address' || true)"
    RES="$RES fsck_names=$(grep -c 'outside every data region' <<<"$out" || true)"
}

round c 1
C="$RES"
log "control (box only): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get same "$R")" = 1 ] && pass "1: the bitmap block is byte-identical after a write through the extent" ||
    fail "1: the write reached the bitmap: $R"
[ "$(get served "$R")" = 0 ] && pass "2: the read did not serve the bitmap" || fail "2: $R"
[ "$(get logged "$R")" -ge 1 ] && [ "$(get fsck_names "$R")" -ge 1 ] &&
    pass "3: the kernel logged the refusal and fsck names the extent" || fail "3: $R"
[ "$(get same "$C")" = 0 ] && pass "control: with the box alone, the write landed on the bitmap" ||
    fail "control: the bitmap was not reached without the fix -- the suite does not aim where it says: $C"
ct_exit
