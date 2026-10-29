#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an inode number is not reused while a stale VFS object still holds it
#
# A real two-node Oops: a freshly allocated inode number was reused for a
# different file TYPE while something still held an in-core inode object
# for that number, and page_symlink() jumped through the old type's NULL
# a_ops. Fixed by deferring the number/block free to VFS eviction, the
# way every real Unix filesystem does it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking inode-number reuse while a stale VFS object is still pinned"
# Its own fresh image: this needs deterministic inode numbering, which a
# volume carrying another suite's creates and deletes could not give.
#
# Real-hardware repro (two-node ctest run): a node crashed with a
# NULL-pointer Oops inside page_symlink() because a freshly allocated
# inode number got reused for a *different* file type while something
# still held an in-core VFS inode object for that number alive (there,
# built up across many prior ctest scenarios in the same long-lived
# mount; here, a plain held-open fd reproduces the same underlying
# condition deterministically). cetrafs_iget()'s cache-hit path only
# ever refreshes stat fields (cetrafs_apply_raw_to_vfs_inode()), never
# i_op/i_fop/i_mapping->a_ops -- so the reused object kept the *old*
# type's operations, and page_symlink()'s direct
# mapping->a_ops->write_begin() call jumped through NULL (directories
# never get cetrafs_aops assigned at all). Fixed by deferring the actual
# inode-number/block free to VFS eviction (super_ops.c's
# cetrafs_evict_inode()) instead of freeing immediately when nlink hits
# 0 -- the same way every real Unix filesystem (ext2, minix, ...) does
# it, so a number can never be handed to a new file while anything still
# references the old one.
REUSE_IMG="$(mktemp /tmp/cetrafs-reuse-XXXXXX.img)"
truncate -s 560M "$REUSE_IMG"
REUSE_LOOPDEV="$(losetup --find --show "$REUSE_IMG")"
REUSE_MNT="$(mktemp -d /tmp/cetrafs-reuse-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$REUSE_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$REUSE_LOOPDEV" "$REUSE_MNT"
require_cetrafs_mount "$REUSE_MNT"

mkdir "$REUSE_MNT/reuse-dir"
REUSE_INO="$(stat -c '%i' "$REUSE_MNT/reuse-dir")"
exec 9<"$REUSE_MNT/reuse-dir"   # pin the directory's VFS inode object open, like a lingering local reference
rmdir "$REUSE_MNT/reuse-dir"    # frees the dirent + (on the buggy kmod) the inode number immediately

if ln -s "some-target" "$REUSE_MNT/reuse-check-symlink" 2>/dev/null; then
    pass "inode-reuse: creating a symlink right after the pinned rmdir didn't crash the kernel"
else
    fail "inode-reuse: creating a symlink right after the pinned rmdir failed"
fi

GOT="$(readlink "$REUSE_MNT/reuse-check-symlink" 2>/dev/null)"
[ "$GOT" = "some-target" ] && pass "inode-reuse: the new symlink works correctly (readlink returns the target)" ||
    fail "inode-reuse: readlink returned '$GOT', expected 'some-target'"

NEW_INO="$(stat -c '%i' "$REUSE_MNT/reuse-check-symlink" 2>/dev/null)"
[ -n "$NEW_INO" ] && [ "$NEW_INO" != "$REUSE_INO" ] &&
    pass "inode-reuse: the new symlink did NOT reuse the still-pinned directory's inode number ($REUSE_INO)" ||
    fail "inode-reuse: the new symlink got ino=$NEW_INO, same as the still-open directory's $REUSE_INO -- reused a live object"

exec 9<&-   # close the pinning fd -- the old directory inode can finally evict, freeing its number

mkdir "$REUSE_MNT/reuse-dir-2"
RECLAIMED_INO="$(stat -c '%i' "$REUSE_MNT/reuse-dir-2")"
[ "$RECLAIMED_INO" = "$REUSE_INO" ] && pass "inode-reuse: closing the pinning fd let ino=$REUSE_INO actually get reclaimed afterward" ||
    fail "inode-reuse: expected the freed ino $REUSE_INO to be reclaimed once unpinned, got $RECLAIMED_INO instead"

umount "$REUSE_MNT"
rmdir "$REUSE_MNT"
losetup -d "$REUSE_LOOPDEV"
rm -f "$REUSE_IMG"


ct_exit
