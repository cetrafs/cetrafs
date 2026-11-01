#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an extent's physical address must be a DATA address before anything maps it
#
# ee_start_hi/lo is 48 bits read off the device. cetrafs_leaf_array_lookup()
# turned it straight into the LBA cetrafs_get_block() hands to map_bh(), so an
# extent pointing at the global inode table made an ordinary write(2) land on
# the inode table. Measured before the guard, on exactly the image this suite
# builds: the records of inodes 1..4 overwritten by file data, and fsck then
# saying "root is not a dir" -- the volume gone, and on a shared LUN gone for
# every node. A read of the same file returned the root inode's record as its
# contents.
#
# The checksum cannot catch this and is not meant to: the helper restamps it,
# so the record is integrity-valid and merely says something impossible.
# cetrafs_blk_struct_ok_magic() validates the counts and lengths read off the
# disk -- name_len, value_len, eh_entries -- and addresses were never part of
# it. That is what cetrafs_lba_run_is_data() closes.
#
# Both directions are asserted, because they fail differently: the READ is a
# metadata disclosure that leaves no trace, and the WRITE is destruction.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_image 560 extphys)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt extphys)"

ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"

# A file with a real inline extent to redirect. Four blocks, so the poisoned
# run covers the records of inodes 1..4 -- the root among them, which is what
# makes the damage unmistakable rather than a subtle miscount.
printf 'victim-content-' > "$MNT/victim"
dd if=/dev/zero of="$MNT/victim" bs=4096 count=4 conv=notrunc status=none
sync
VICTIM_INO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"

# Redirect the extent, and learn from the poker itself where the inode table
# starts. A run that does not redirect anything exits nonzero rather than
# leaving the suite to assert over a file whose blocks were never moved --
# without that, the mount stays clean, the read returns the file's own bytes,
# and "the table was not damaged" is green because nothing ever aimed at it.
POKED="$("$PPOKE" "$IMG" "$VICTIM_INO" inode_table)" ||
    fail "setup: extent_phys_poke refused to redirect the victim's extent: $POKED"
TABLE_LBA="$(echo "$POKED" | sed -n 's/.*-> \([0-9][0-9]*\) .*/\1/p')"
[ -n "$TABLE_LBA" ] || fail "setup: could not learn where the inode table starts from: $POKED"
blockdev --flushbufs "$DEV"
pass "setup: the victim's extent now names the inode table (block $TABLE_LBA)"

# The bytes the file must be able neither to serve nor to destroy. Block
# TABLE_LBA holds inode 1 (the root); the poke above rewrote the VICTIM's
# record, which is a different block, so hashing after the poke is the same as
# hashing before it.
[ "$VICTIM_INO" != 1 ] || fail "setup: the victim is inode 1, so this hash would include the poke"
TBEFORE="$(ct_tmp table-before)"
dd if="$IMG" bs=4096 skip="$TABLE_LBA" count=1 of="$TBEFORE" status=none
TABLE_BEFORE="$(sha256sum < "$TBEFORE" | cut -d' ' -f1)"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"

# --- direction 1: the read must not serve metadata -------------------------
RBACK="$(ct_tmp read-back)"
dd if="$MNT/victim" bs=4096 count=1 of="$RBACK" status=none 2>/dev/null || true
READ_BACK="$(sha256sum < "$RBACK" | cut -d' ' -f1)"
if [ "$READ_BACK" = "$TABLE_BEFORE" ]; then
    fail "reading the file returned the inode table verbatim -- metadata served as file content"
else
    pass "the read did not serve the inode table"
fi

# --- direction 2: the write must not reach metadata ------------------------
dd if=/dev/urandom of="$MNT/victim" bs=4096 count=4 conv=notrunc status=none 2>/dev/null || true
sync
ct_umount "$MNT"

TAFTER="$(ct_tmp table-after)"
dd if="$IMG" bs=4096 skip="$TABLE_LBA" count=1 of="$TAFTER" status=none
TABLE_AFTER="$(sha256sum < "$TAFTER" | cut -d' ' -f1)"
if [ "$TABLE_AFTER" != "$TABLE_BEFORE" ]; then
    fail "the write reached the inode table -- its first block changed"
else
    pass "the inode table is byte-identical after writing through the poisoned extent"
fi

# The volume must still be usable, which is the consequence that matters:
# "root is not a dir" is what the unguarded kernel left behind.
OUT="$(ct_tmp fsck-out)"
"$ROOT/userspace/fsck.cetra" "$DEV" >"$OUT" 2>&1 || true
# Any complaint about the ROOT, not one spelling of it: what the random
# bytes landing on inode 1 produce varies -- "root is not a dir" when they
# hit the mode, a CRC/identity mismatch when they hit anything else. The
# first version of this assertion grepped only the former and passed, once,
# against a kernel with the guard removed.
if grep -qE "^ERR: root " "$OUT"; then
    fail "the root inode was damaged: $(grep -E '^ERR: root ' "$OUT" | head -1)"
else
    pass "the root inode survived"
fi

# fsck must still NAME the bad extent. The kernel refusing to follow it is not
# a repair, and a suite that only looked for damage would pass equally well
# against a kernel that silently dropped the file's blocks.
if grep -qE "outside every data region" "$OUT"; then
    pass "fsck still reports the extent as outside every data region"
else
    fail "fsck went quiet about the poisoned extent: $(grep -E '^(ERR|WARN)' "$OUT" | head -2 | tr '\n' ' ')"
fi

# And the refusal must be visible, so an operator can tell a refused mapping
# from an empty file.
#
# Scoped to THIS run with dmesg_since(). The first spelling grepped
# `dmesg | tail -300` and passed against a kernel with the guard removed,
# because the message from the previous (fixed) run was still in the ring
# buffer -- a test that can pass for a reason that has nothing to do with
# the code under it.
if dmesg_since "$MARK" | grep -q "is not a data address"; then
    pass "the kernel logged the refusal"
else
    fail "the kernel refused the mapping without saying so"
fi

ct_exit
