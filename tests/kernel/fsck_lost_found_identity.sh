#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck must not adopt whatever a dirent calls /lost+found
#
# Before grafting orphans, fsck looks for an existing /lost+found in the
# root directory and reads the inode that entry names. The number came
# off the device, and the read was `inode_table_start + (ino - 1)` with
# no bound: past the end of the table that addresses the DATA REGION,
# where the bytes are whatever a user wrote into their own file.
#
# So a volume with a corrupted root dirent -- or a user who wrote a
# plausible record into their own file and then got the dirent repointed
# at it -- hands fsck an attacker-chosen "directory", and `fsck -r`
# writes orphan entries into it. A repair tool writing where it is told
# by the thing it is repairing.
#
# Two guards, because they answer different questions: the read itself
# refuses a number outside the table, and the lost+found site requires
# the record to pass its own checksums AND to echo the number it was
# looked up by (a valid record belonging to a different inode is not
# /lost+found either).
#
# Since the inode table is chained (M-36), a number past its end has no
# slot at all -- it no longer lands in the data region -- so the forgery
# is the bare number: the read must still refuse it, and fsck -r must
# write nothing through it (the block the old formula addressed is
# watched, as before).
#
# Discrimination: before M-36, dropping the range check in
# fsck_read_inode() made fsck adopt a record planted in the data region.
# A number past the chained table now has no slot to plant in, so the
# second guard (checksums and the echoed number) refuses it as well: the
# suite holds the outcome -- refused, nothing written -- not one guard.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"
CORRUPT="$(ct_helper corrupt_poke)"

IMG="$(ct_image 560 lfident)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lfident)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/lost+found"
echo payload > "$MNT/orphan"
sync
ct_umount "$MNT"

# An orphan to recover: a live link count with nothing naming it, which
# is the only reason fsck goes looking for /lost+found at all.
"$CORRUPT" "$IMG" dirent 1 orphan >/dev/null ||
    fail "could not erase the dirent -- the setup did not arrange the situation"

SBPOKE="$(ct_helper sb_poke)"
INODES="$("$SBPOKE" "$IMG" | sed -n 's/^inodes_count[^0-9]*\([0-9]*\).*/\1/p' | head -1)"
TBL="$("$SBPOKE" "$IMG" | sed -n 's/^inode_table_start[^0-9]*\([0-9]*\).*/\1/p' | head -1)"
[ -n "$INODES" ] && [ -n "$TBL" ] ||
    fail "could not read inodes_count/inode_table_start out of the superblock"

# The forged number addresses a block in the middle of the first Block
# Group, past its header and bitmap: user data, which fsck must never
# write. INODES + 64 once did; the tables after the inode table (the
# Node Registry, the queues, the journals) grew, and it landed on a
# registry row instead -- which fsck -r rightly rebuilt, failing this
# suite for the wrong reason.
BGR="$("$SBPOKE" "$IMG" | sed -n 's/^bg_regions_start=//p')"
BGSZ="$("$SBPOKE" "$IMG" | sed -n 's/^bg_size_blocks=//p')"
SLOT=$((BGR + BGSZ / 2))                      # the block that number addresses
FORGED=$((SLOT - TBL + 1))
IMG_BLOCKS=$(( $(stat -c %s "$IMG") / 4096 ))
[ -n "$BGR" ] && [ -n "$BGSZ" ] && [ "$FORGED" -gt "$INODES" ] && [ "$SLOT" -lt "$IMG_BLOCKS" ] ||
    fail "setup: the forged slot ($SLOT, number $FORGED) is not in the first group's data region -- it must be, to prove anything"

"$CORRUPT" "$IMG" repoint 1 lost+found "$FORGED" >/dev/null 2>&1 ||
    fail "could not repoint the lost+found entry"

BEFORE="$(dd if="$IMG" bs=4096 skip="$SLOT" count=1 2>/dev/null | md5sum)"

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"

AFTER="$(dd if="$IMG" bs=4096 skip="$SLOT" count=1 2>/dev/null | md5sum)"

echo "$OUT" | grep -qE "outside the inode table|does not check out" &&
    pass "fsck refuses the forged /lost+found entry" ||
    fail "fsck accepted an inode number past the end of the table: $(echo "$OUT" | grep -iE "lost|orphan" | head -1)"

[ "$AFTER" = "$BEFORE" ] &&
    pass "and wrote nothing into the block that number addresses" ||
    fail "fsck -r wrote into the data region through a forged inode number"

ct_exit
