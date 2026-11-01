#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs refuses a superblock whose geometry the mount would refuse, and writes nothing
#
# growfs checked the superblock's magic, version and checksum -- which
# prove it is the one written, not that it is sane -- and then did its
# arithmetic with zone_group_count, block_group_count and bg_size_blocks
# as found. A volume with zero Zone Groups "completed" a grow (the mount
# refuses that volume before and after), and a zero divisor is what some
# of that arithmetic divides by.
#
# DISCRIMINATION (measured on the unfixed code): growfs exits 0 and
# reports "completed" for zone_group_count=0 and for bg_size_blocks=0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 600 gbadgeo)"
for case in "zone_group_count 0" "zone_group_count 9999" "bg_size_blocks 0" "bg_size_blocks 63"; do
    set -- $case
    truncate -s 600M "$IMG"
    DEV="$(ct_loop "$IMG")"
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    "$SBPOKE" "$DEV" "$1" "$2" >/dev/null
    before="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
    losetup -d "$DEV"
    truncate -s 1200M "$IMG"
    DEV="$(ct_loop "$IMG")"
    rc=0
    out="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" || rc=$?
    after="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
    if [ "$rc" = 0 ]; then
        fail "$1=$2: growfs accepted it: $(tail -1 <<<"$out")"
    elif [ "$rc" -ge 128 ]; then
        fail "$1=$2: growfs died on a signal (rc=$rc)"
    else
        pass "$1=$2: growfs refused ($(grep -m1 -o 'invalid [a-z_]* [0-9]*' <<<"$out" || echo "rc=$rc"))"
    fi
    [ "$before" = "$after" ] && pass "$1=$2: the superblock is untouched" ||
        fail "$1=$2: growfs rewrote the superblock of a volume it should have refused"
    losetup -d "$DEV"
done
ct_exit
