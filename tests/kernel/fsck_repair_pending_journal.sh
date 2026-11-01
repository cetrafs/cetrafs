#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not repair a volume whose journal still holds entries a mount will apply
#
# A journal entry that survives a crash means "this block's new image
# never reached it"; the next mount replays it. fsck read the journal,
# checked each entry's checksums -- and then reconciled the volume as if
# the entries did not exist. A create that crashed between journaling
# its dirent and writing it leaves an inode allocated, linked once, that
# no directory names: fsck -r linked it into lost+found. The next mount
# replayed the dirent, and the inode had two names under nlink=1 --
# unlinking either one frees the blocks the other names. The same holds
# for an extent leaf (fsck -r clears the bits of blocks only the
# replayed leaf references) and an xattr block. The comment there even
# said the verdict was "provisional until it is replayed by a mount";
# the code did not act on it.
#
# Now an entry that is valid, not for a fresh block, and not already
# on its target blocks the repair; a mount replays it, and fsck -r after
# that has nothing to undo.
#
# The test builds exactly that crash: D/b's dirent block is put back to
# its image before the create, and the create's journal entry for it is
# left pending (guarded against the current target, as journal.c writes
# it).
#
# DISCRIMINATION (measured on the unfixed code): fsck -r links b's
# inode into lost+found, the mount's replay names it in D as well, and
# fsck then finds nlink=1 under two names.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
JPOKE="$(ct_helper journal_poke)"

DEV="$(ct_dev 560 fsckjrnl)"
MNT="$(ct_mnt fsckjrnl)"
BEFORE="$(ct_tmp)"
AFTER="$(ct_tmp)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/D"
touch "$MNT/D/a"
DINO="$(stat -c %i "$MNT/D")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
LBA="$(awk '/^ext 0 /{split($4,a,"="); print a[2]}' <<<"$("$IPOKE" "$DEV" extents "$DINO")")"
dd if="$DEV" of="$BEFORE" bs=4096 skip="$LBA" count=1 status=none

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/D/b"
BINO="$(stat -c %i "$MNT/D/b")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
dd if="$DEV" of="$AFTER" bs=4096 skip="$LBA" count=1 status=none
cmp -s "$BEFORE" "$AFTER" && { fail "setup: D's block $LBA did not change with the create"; ct_exit; }

# The crash: the dirent write never landed; its journal entry did.
dd if="$BEFORE" of="$DEV" bs=4096 seek="$LBA" count=1 conv=notrunc status=none
"$JPOKE" "$DEV" 0 0 "$LBA" "$AFTER" --guard-current >/dev/null
blockdev --flushbufs "$DEV"
pass "crash state built: D's block $LBA without b, its entry pending; b is inode $BINO"

out="$(ct_fsck_repair "$DEV" 2>&1)" || true
if grep -q "not yet applied to block $LBA" <<<"$out" && grep -q "NOTE: repair is disabled" <<<"$out"; then
    pass "fsck -r saw the pending entry and repaired nothing"
else
    fail "fsck -r repaired around a journal entry a mount will replay: $(grep -E 'lost\+found|NOTE|repaired' <<<"$out" | head -3 | tr '\n' ' ')"
fi

# What the next mount does: replay. Then the volume must add up.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
[ -e "$MNT/D/b" ] && pass "the mount replayed the entry: D names b" || fail "D/b is missing after the replay"
ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if grep -qE "^ERR: inode $BINO has nlink=[0-9]+ but [0-9]+ directory entries" <<<"$out"; then
    fail "b's inode is named more often than it is counted: $(grep "^ERR: inode $BINO" <<<"$out")"
elif [ "$rc" = 0 ] && ! grep -q '^ERR' <<<"$out"; then
    pass "fsck clean after the replay: nothing was repaired that the replay then contradicted"
else
    fail "fsck rc=$rc after the replay: $(grep '^ERR' <<<"$out" | head -3)"
fi

ct_exit
