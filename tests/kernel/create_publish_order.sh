#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Creation order: a child is built and labelled BEFORE its name exists
#
# create/mkdir/symlink used to publish the name (cetrafs_dir_add_entry)
# first and finish building the child afterwards -- the LSM security label,
# and for a symlink the target text itself. From the instant the dirent
# landed, a peer could resolve the name and take the child's namespace lock
# for a setxattr/chmod while init_security mutated the same record under no
# lock at all (a lost update), could see the file unlabelled, or could
# readlink a symlink whose target text was not yet durable. All three paths
# now share cetrafs_create_publish(): instantiate, write content, label --
# and only then add the name.
#
# Two actors cannot race on one node (the VFS serializes the parent), but
# the ORDER is directly observable on disk: with the new order, a creation
# that fails before publishing must leave the parent's inode record
# byte-for-byte untouched -- no dirent_seq bump, no size/mtime churn,
# because add_entry was never called. The old order's unwind was
# add_entry + remove_entry, which moved dirent_seq twice and redirtied the
# parent: the byte-compare below fails against it, so this suite
# discriminates. The symlink_fail_after_write knob supplies the late
# failure (after the target text: inode + data block exist, name must not).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 pubord)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pubord)"
ct_mkfs_small "$DEV" -M 4 >/dev/null

log "setup: a parent directory, settled on disk"
mount -t cetrafs "$DEV" "$MNT"
mkdir "$MNT/d"
DINO="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
BASE="$("$IPOKE" "$DEV" dump "$DINO")"

# Control for the control: a mount/umount cycle that does nothing must not
# dirty the parent record, or the comparison below would be meaningless.
mount -t cetrafs "$DEV" "$MNT"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
[ "$("$IPOKE" "$DEV" dump "$DINO")" = "$BASE" ] &&
    pass "an idle mount cycle leaves the parent record byte-identical (comparison is meaningful)" ||
    fail "the parent record changes across an idle mount cycle -- this suite cannot compare records"

log "a creation that fails BEFORE publishing must leave the parent untouched"
ct_param_set symlink_fail_after_write 1
mount -t cetrafs "$DEV" "$MNT"
if ln -s "some-target" "$MNT/d/link" 2>/dev/null; then
    fail "the forced-failure symlink SUCCEEDED -- the knob is not wired"
else
    pass "the symlink failed as forced (inode + target block existed; the name must not)"
fi
ct_param_set symlink_fail_after_write 0
[ ! -e "$MNT/d/link" ] && pass "no name left behind by the failed creation" ||
    fail "'link' exists after the forced failure"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"

# THE assertion. The old publish-first order ran add_entry + remove_entry
# on this failure path: dirent_seq moved twice, size/mtime redirtied, and
# this compare failed. Name-last leaves the parent provably untouched.
[ "$("$IPOKE" "$DEV" dump "$DINO")" = "$BASE" ] &&
    pass "the parent's on-disk record is byte-identical: the name was never published" ||
    fail "the parent record CHANGED across a failed creation -- the name was published before the child was built"

# The discard must have freed the half-built child (inode + target data
# block) through eviction -- a leak or a double free both surface here.
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after the unwind (no leaked inode/block, no double free)" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

log "control: a SUCCESSFUL creation does change the parent (the compare can fail)"
mount -t cetrafs "$DEV" "$MNT"
ln -s "some-target" "$MNT/d/link"
[ "$(readlink "$MNT/d/link")" = "some-target" ] && pass "the control symlink resolves" ||
    fail "control symlink broken: $(readlink "$MNT/d/link" 2>&1)"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
[ "$("$IPOKE" "$DEV" dump "$DINO")" != "$BASE" ] &&
    pass "a successful creation moves the parent record (negative control)" ||
    fail "the parent record did not change even for a SUCCESSFUL creation -- the dump is not sensitive"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
