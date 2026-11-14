#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs checks the data-area layout before its first write, and refuses one that does not hold
#
# growfs writes Block Group headers and zeroed bitmaps (STEP 1) before it
# publishes anything, at new_bg_start, which it takes from bg_data_end
# (or from the regions' end when that is zero). Its validation proved
# magic, version, CRC and a few counts, and never that the data area the
# superblock describes holds the Block Groups it already has. A CRC-valid
# superblock whose bg_data_end lies below regions_start + block_group_count
# * bg_size_blocks (the kernel's mount refuses that, and so does fsck)
# made growfs write headers and zeroed bitmaps over live groups before
# any publish (audit 2026-11-14 U3).
#
# The suite poses that superblock on a two-or-more-group volume and
# grows it. growfs must refuse, and the live groups' headers and the
# superblock must be untouched afterwards. A control volume with the
# unpoked superblock must grow, so the refusal is the layout's and not
# the geometry's.
#
# DISCRIMINATION (measured on the unfixed code): growfs grows the poked
# volume and rewrites the second group's header.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 1700 ggrowlayout)"
truncate -s 1200M "$IMG"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
DUMP="$("$SBPOKE" "$DEV")"
B="$(sed -n 's/.*block_group_count[^0-9]*\([0-9][0-9]*\).*/\1/p' <<<"$DUMP" | head -1)"
RS="$(sed -n 's/.*bg_regions_start[^0-9]*\([0-9][0-9]*\).*/\1/p' <<<"$DUMP" | head -1)"
BS="$(sed -n 's/.*bg_size_blocks[^0-9]*\([0-9][0-9]*\).*/\1/p' <<<"$DUMP" | head -1)"
log "layout: block_group_count=$B bg_regions_start=$RS bg_size_blocks=$BS"
if [ -z "$B" ] || [ -z "$RS" ] || [ -z "$BS" ] || [ "$B" -lt 2 ]; then
    fail "setup: the volume does not have two Block Groups to protect ($DUMP)"
    losetup -d "$DEV"
    ct_exit
fi
losetup -d "$DEV"

# Control: the same volume, unpoked, grows.
truncate -s 1700M "$IMG"
DEV="$(ct_loop "$IMG")"
rc=0
"$ROOT/userspace/growfs.cetra" "$DEV" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "control: the unpoked volume grows" || fail "control: growfs refused a sound volume (rc $rc)"
losetup -d "$DEV"

# Poisoned: the data area ends one group past the regions' start, short of
# the groups the superblock already holds.
truncate -s 1200M "$IMG"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
"$SBPOKE" "$DEV" bg_data_end "$((RS + BS))" >/dev/null
blockdev --flushbufs "$DEV"
sb_before="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
g1_before="$(dd if="$DEV" bs=4096 skip="$((RS + BS))" count=1 status=none | sha256sum)"
losetup -d "$DEV"
truncate -s 1700M "$IMG"
DEV="$(ct_loop "$IMG")"
rc=0
OUT="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" || rc=$?
blockdev --flushbufs "$DEV"
sb_after="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
g1_after="$(dd if="$DEV" bs=4096 skip="$((RS + BS))" count=1 status=none | sha256sum)"

if [ "$rc" -ge 128 ]; then
    fail "growfs died on a signal (rc=$rc)"
elif [ "$rc" = 0 ]; then
    fail "growfs grew a volume whose data area does not hold its Block Groups"
else
    pass "growfs refused the volume before writing ($(tail -1 <<<"$OUT"))"
fi
[ "$g1_before" = "$g1_after" ] && pass "the second Block Group's header is untouched" ||
    fail "growfs wrote over the second Block Group's header (a live group)"
[ "$sb_before" = "$sb_after" ] && pass "the superblock is untouched" ||
    fail "growfs rewrote the superblock of a volume it should have refused"
losetup -d "$DEV"
ct_exit
