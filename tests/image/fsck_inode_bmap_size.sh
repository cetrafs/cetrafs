#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck refuses an inode bitmap of any size but the one its count needs
#
# fsck reads the inode bitmap whole, into a buffer sized by the
# superblock's inode_bmap_blocks. It checked only that the field is
# nonzero, covers inodes_count, and (in the overlap pass) fits the
# volume -- so a CRC-valid superblock naming a bitmap far larger than
# its count, placed in free space, had fsck allocate and read whatever
# it said (terabytes, on a large LUN), and on a smaller scale passed it
# as clean (audit 2026-11-11 F2). mkfs writes exactly
# cetrafs_calc_inode_bmap_blocks(inodes_count), and nothing changes it.
#
# The rig: move the bitmap, contents and all, to the free slack between
# the data area and the end of the volume, and make it one block longer
# than its count needs -- a layout every other check accepts.
#
#  0. moved but the right size: clean (the move itself is legal).
#  1. one block longer: fsck refuses it, naming the field.
#
# DISCRIMINATION (2026-11-11, fsck.c before this fix): 1 exits 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
field() { "$SBPOKE" "$DEV" | sed -n "s/^$1=//p"; }

IMG="$(ct_image 600 ibmsz)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
TOT="$(field total_blocks)"; RS="$(field bg_regions_start)"; BGS="$(field bg_size_blocks)"
BGC="$(field block_group_count)"; IBS="$(field inode_bmap_start)"; IBB="$(field inode_bmap_blocks)"
END=$((RS + BGC * BGS)); NEW=$((END + 4))
[ "$IBB" = 1 ] || { fail "setup: expected a 1-block bitmap for 1024 inodes, got $IBB"; ct_exit; }
[ $((TOT - NEW)) -ge 4 ] || { fail "setup: no slack after the data area ($END..$TOT)"; ct_exit; }
dd if="$DEV" of="$DEV" bs=4096 skip="$IBS" seek="$NEW" count=1 conv=notrunc,fsync status=none
"$SBPOKE" "$DEV" inode_bmap_start "$NEW" >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 && pass "0: the bitmap moved to $NEW (slack $END..$TOT) is clean" ||
    { fail "0 setup: the moved bitmap is not clean: $(ct_fsck "$DEV" 2>&1 | grep -m2 ERR)"; ct_exit; }

log "1: inode_bmap_blocks 2 for 1024 inodes"
dd if=/dev/zero of="$DEV" bs=4096 seek=$((NEW + 1)) count=1 conv=notrunc,fsync status=none
"$SBPOKE" "$DEV" inode_bmap_blocks 2 >/dev/null
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "inode_bmap_blocks 2" <<<"$OUT" && pass "1: refused: $(grep -m1 inode_bmap_blocks <<<"$OUT")" ||
    fail "1: fsck exit $rc: $(grep -m1 -E 'ERR|OK' <<<"$OUT")"
losetup -d "$DEV"
ct_exit
