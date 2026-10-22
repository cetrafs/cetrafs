#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a cached dentry must not keep resolving a file the namespace lost
#
# N1 stopped cetrafs_iget()'s FILL path from instantiating a record
# whose nlink is 0. The likelier route is this one: the node with a
# cached dentry and a cached in-core inode is exactly the node whose
# dirent block may still name the file after a peer unlinked it. On
# that path iget is a cache HIT, so N1's guard never runs.
#
# Measured before the fix: a record set to nlink=0 behind a live mount
# left the name resolving, `stat` cheerfully reporting nlink 0, and
# `cat` still returning the data -- out of extents the allocator has
# taken back.
#
# The guard went into cetrafs_apply_raw_to_vfs_inode() rather than into
# d_revalidate, for the reason P4 and P6 both found the hard way: a rule
# every caller has to re-derive is a rule one of them will get wrong.
# Three callers reach it -- d_revalidate, iget's cache-hit path, and
# lock.c's open-boundary refresh -- and this asserts all three.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 reval)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt reval)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PAYLOAD="data that a peer has deleted"
echo "$PAYLOAD" >"$MNT/v"
echo "untouched" >"$MNT/keep"
INO="$(stat -c '%i' "$MNT/v")"
# Cache the dentry and the in-core inode -- without this the next
# lookup takes iget's fill path and N1's guard answers instead.
cat "$MNT/v" >/dev/null
stat "$MNT/v" >/dev/null
sync

log "a peer's unlink, seen through an already-cached dentry"
"$POKE" "$IMG" nlink "$INO" 0 >/dev/null 2>&1

if OUT="$(stat -c '%h' "$MNT/v" 2>&1)"; then
    fail "stat still resolved the cached dentry after the record went to nlink=0 (reported nlink=$OUT)"
else
    pass "stat refuses a cached dentry whose record says nlink=0"
fi
if OUT="$(cat "$MNT/v" 2>&1)"; then
    fail "open/read still served the deleted file: '$OUT'"
else
    pass "open refuses it too"
fi
[ "$(cat "$MNT/keep")" = "untouched" ] &&
    pass "an unrelated cached dentry in the same directory still works" ||
    fail "the refusal broke unrelated cached dentries"

log "control: it resolves again once the record is live"
"$POKE" "$IMG" nlink "$INO" 1 >/dev/null 2>&1
if [ "$(cat "$MNT/v" 2>&1)" = "$PAYLOAD" ]; then
    pass "control: with nlink restored the same cached dentry reads correctly"
else
    fail "control: the name does not resolve even with nlink=1 -- the refusals above proved nothing"
fi

log "ordinary revalidate behaviour is unchanged"
# A negative dentry is never trusted (a peer may have created the name),
# and a positive one survives ordinary use.
[ -e "$MNT/nope" ] && fail "a name that does not exist resolved" || pass "a negative dentry stays negative"
: >"$MNT/nope"
[ -e "$MNT/nope" ] && pass "a name created after the negative lookup is seen immediately" ||
    fail "the negative dentry was cached and hid a newly created name"
# Repeated stats of a dirty inode must not churn: d_revalidate now
# invalidates on any refresh error, and the refresh returns 0 (not an
# error) when it declines because the inode has unwritten changes.
echo more >>"$MNT/keep"
for _ in 1 2 3 4 5; do stat "$MNT/keep" >/dev/null || fail "stat of a dirty inode failed"; done
[ "$(stat -c '%s' "$MNT/keep")" -gt 9 ] &&
    pass "repeated stats of a dirty inode keep working and keep its in-core size" ||
    fail "a dirty inode's size was reverted by a refresh"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -2)"
ct_exit
