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
# plantrec writes a correctly-stamped record at the slot an arbitrary
# number addresses, which is exactly the forgery being defended against.
#
# Discrimination: drop the range check in fsck_read_inode() and fsck
# adopts the planted record -- the assertion below sees its block
# rewritten.
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

FORGED=$((INODES + 64))                       # past the table, inside the device
SLOT=$((TBL + FORGED - 1))                    # the block that number addresses
IMG_BLOCKS=$(( $(stat -c %s "$IMG") / 4096 ))
[ "$SLOT" -lt "$IMG_BLOCKS" ] ||
    fail "the forged slot ($SLOT) is past the end of the image -- it must land in the data region to prove anything"

"$POKE" "$IMG" plantrec "$FORGED" 040755 2>/dev/null ||
    fail "could not plant a record at the forged slot"
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
