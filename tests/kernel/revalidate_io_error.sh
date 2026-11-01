#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a revalidation that cannot determine validity must not destroy mounts
#
# .d_revalidate has three answers and this returned only two of them.
# Anything other than "still valid" became 0 -- including a device error
# reading the directory, which is not "this dentry is invalid", it is "I
# could not find out".
#
# The VFS answers a 0 with d_invalidate(): the dentry is unhashed and
# ANY MOUNTS ON IT ARE DETACHED. So one transient -EIO on a single
# directory block was enough to tear down a bind mount, permanently and
# silently, on a path that merely walked through it.
#
# Only -ESTALE -- same inode number, different file -- genuinely means
# invalid. -EIO and -EUCLEAN mean the record could not be read or did
# not validate, and the honest answer is the errno: the mount is left
# alone and the caller is told.
#
# Discrimination: return 0 instead of the errno and the bind mount below
# is gone after a single stat.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 revalio)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt revalio)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir -p "$MNT/source" "$MNT/mountpoint"
echo payload > "$MNT/source/file"
mount --bind "$MNT/source" "$MNT/mountpoint"
ct_track mnt "$MNT/mountpoint"

grep -q " $MNT/mountpoint " /proc/mounts &&
    pass "a bind mount is in place on a cetrafs dentry" ||
    fail "could not establish the bind mount"

# Walk through the mount point with the next revalidation unable to
# determine anything, exactly as a device error would leave it.
ct_param_set revalidate_fail_once 1
RC=0
stat "$MNT/mountpoint/file" >/dev/null 2>&1 || RC=$?
ct_param_set revalidate_fail_once 0
log "stat through the mount point during the failure: rc=$RC"

# THE assertion. The lookup is allowed to fail; the mount is not
# allowed to disappear.
grep -q " $MNT/mountpoint " /proc/mounts &&
    pass "the bind mount survived a revalidation that could not determine validity" ||
    fail "the bind mount was DETACHED: d_revalidate answered 'invalid' to a question it could not answer, and the VFS took the mounts with it"

# And it still works afterwards -- a surviving-but-broken mount would be
# no better.
[ "$(cat "$MNT/mountpoint/file" 2>/dev/null)" = "payload" ] &&
    pass "and it still resolves" ||
    fail "the mount is present but no longer usable"

# A genuinely invalid dentry must still be invalidated: the fix must not
# have turned every failure into "still valid".
rm -f "$MNT/source/file"
[ ! -e "$MNT/mountpoint/file" ] &&
    pass "a name that really went away is still seen as gone" ||
    fail "a deleted name is still resolving -- invalidation stopped working"

umount "$MNT/mountpoint" 2>/dev/null || true
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
