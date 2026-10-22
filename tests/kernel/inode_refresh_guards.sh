#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refresh never changes an inode's identity or type, and never clobbers
#
# cetrafs_apply_raw_to_vfs_inode() stamps a freshly-read record's stat
# fields onto a resident in-core inode. Three things must stop it, and
# all three used to be the CALLER's job -- which is how two of them came
# to be missing from one caller each:
#
#  * a different FILE (the number was reused): stamping the new file's
#    fields onto an object instantiated from the old one leaves it
#    wearing the old type's i_op/i_fop. The caught-in-the-wild case was a
#    cached symlink object reused for a regular file, after which the VFS
#    walked the new file's data as a link target. The generation check
#    lived only in cetrafs_refresh_vfs_inode_if_newer(); lock.c's
#    open-boundary refresh calls apply() directly, comparing only mtime,
#    so a number reused between a lookup and the open that followed it
#    went straight past the protection.
#  * a different TYPE with the same generation: unreachable if the
#    generation check holds, which is exactly why it is worth saying out
#    loud if it ever happens rather than type-confusing the VFS.
#  * UNWRITTEN LOCAL CHANGES: covered by
#    kernel/record_write_vs_fresh_read.sh.
#
# All three now live in apply() itself.
#
# Measured discrimination: removing the TYPE guard fails the first two
# assertions -- the inode comes back claiming to be a directory while
# still holding regular-file ops, with nothing in dmesg. The reused-number
# assertion passes either way here, because on a single node the lookup
# path's own generation check gets there first; the apply-level check
# exists for lock.c's open-boundary refresh, which bypasses that path,
# and isolating it needs two nodes. Kept as a statement of the invariant.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 560 irg)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt irg)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "checking a type change with an unchanged generation is refused"
echo hello >"$MNT/typed"
TINO="$(stat -c '%i' "$MNT/typed")"
cat "$MNT/typed" >/dev/null          # resident, cached, instantiated as a regular file
sync
# Rewrite the record as a DIRECTORY, same generation, valid checksum --
# what a generation collision would look like. Poked on the backing file
# behind the live mount, the way a peer's write appears to this node.
"$POKE" "$IMG" retype_keep_gen "$TINO" >/dev/null
MARK="$(dmesg_mark)"
# Drive a refresh: a lookup of the already-cached name.
stat "$MNT/typed" >/dev/null 2>&1 || true
TYPE_NOW="$(stat -c '%F' "$MNT/typed" 2>/dev/null || echo gone)"
if [ "$TYPE_NOW" = "directory" ]; then
    fail "refresh guards: the inode now claims to be a directory while holding regular-file ops"
else
    pass "refresh guards: the type change was not applied (still '$TYPE_NOW')"
fi
if dmesg_since "$MARK" | grep -q "refusing a refresh that would change its type"; then
    pass "refresh guards: dmesg names the refused type change"
else
    fail "refresh guards: the type change was refused silently -- nothing in dmesg"
fi
# And the filesystem is still usable around it.
: >"$MNT/after" && pass "refresh guards: unrelated work still succeeds" ||
    fail "refresh guards: a refused refresh broke the mount"
ct_umount "$MNT"

log "checking the open path honours the generation, not just lookup"
ct_mount "$DEV" "$MNT"
echo data >"$MNT/gen"
GINO="$(stat -c '%i' "$MNT/gen")"
cat "$MNT/gen" >/dev/null
sync
ct_umount "$MNT"
# Same number, different file: a new generation and a different type.
"$POKE" "$IMG" retype "$GINO" 999999 >/dev/null
ct_mount "$DEV" "$MNT"
MARK2="$(dmesg_mark)"
# Whichever path gets there first -- lookup's revalidate or the open's
# refresh -- must notice the number is a different file now. What must
# NOT happen is the new record's fields landing on the old object.
cat "$MNT/gen" >/dev/null 2>&1 || true
GTYPE="$(stat -c '%F' "$MNT/gen" 2>/dev/null || echo gone)"
[ "$GTYPE" = "regular file" ] &&
    pass "refresh guards: the reused number resolved to a correctly-typed object ($GTYPE)" ||
    fail "refresh guards: reused number came back as '$GTYPE'"
ct_umount "$MNT"

# Deliberately NO fsck assertion here. This suite ends with an image that
# has been corrupted on purpose -- a record retyped behind the mount's
# back -- so "fsck is clean" would be the wrong thing to want, and "fsck
# complains" would only be testing the poke. What is under test is that
# the KERNEL refused to act on those records; fsck's opinion of the
# wreckage afterwards says nothing about that.

ct_exit
