#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory's extent pointing outside the data area is refused, not followed
#
# The regular-file path checks every extent address against the data
# area (rule 19); a directory checked only its depth-1 leaf address, and
# its depth-0 inline extents went straight to dirent-block reads and
# rewrites. The dirent tail checksum refused most such blocks, but that
# is a checksum standing in for an address check: a valid dirent block
# image placed anywhere -- here, in an unused slot of the inode table --
# passes it, and lookups, readdir and creates then read and rewrite the
# global table through the directory.
#
# DISCRIMINATION (measured on the old code): the listing shows the planted
# name and the create rewrites the inode-table block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
EXTENT="$(ct_helper pending_poke)"
PHYS_POKE="$(ct_helper extent_phys_poke)"
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 hdir)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hdir)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/planted"
sync
DINO="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"

DBLK="$("$EXTENT" "$IMG" extent "$DINO" | cut -d' ' -f1)"
ITS="$("$BG_POKE" "$IMG" 0 --dump | grep -oP 'inode_table_start=\K[0-9]+')"
# The record slot of inode 1001: in the inode table, unused on a volume
# this young.
TARGET=$((ITS + 1000))
[ -n "$DBLK" ] && [ "$DBLK" -gt 0 ] && [ -n "$ITS" ] || { fail "setup: block=$DBLK inode_table_start=$ITS"; ct_exit; }
dd if="$IMG" of="$IMG" bs=4096 skip="$DBLK" seek="$TARGET" count=1 conv=notrunc status=none
"$PHYS_POKE" "$IMG" "$DINO" "$TARGET" >/dev/null || { fail "setup: could not redirect the directory's extent"; ct_exit; }
pass "setup: directory $DINO now names inode-table block $TARGET, which holds a valid dirent block"
BEFORE="$(dd if="$IMG" bs=4096 skip="$TARGET" count=1 status=none | sha256sum | cut -d' ' -f1)"

ct_mount "$DEV" "$MNT"
MARK="$(dmesg_mark)"
LIST="$(ls "$MNT/d" 2>/dev/null || true)"
touch "$MNT/d/new" 2>/dev/null || true
sync
ct_umount "$MNT"

grep -qx planted <<<"$LIST" && fail "the directory was read through an extent in the inode table (listed: $LIST)" ||
    pass "nothing was listed through the inode-table address"
[ "$(dd if="$IMG" bs=4096 skip="$TARGET" count=1 status=none | sha256sum | cut -d' ' -f1)" = "$BEFORE" ] &&
    pass "the inode-table block was not rewritten through the directory" ||
    fail "a create rewrote an inode-table block through the directory's extent"
grep -q "outside the data area" <<<"$(dmesg_since "$MARK")" && pass "the refusal names the extent" ||
    fail "no refusal logged"
ct_exit
