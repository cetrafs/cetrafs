#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a metadata operation must not leave the inode dirty with nothing unwritten
#
# cetrafs_apply_raw_to_vfs_inode() refuses to refresh a DIRTY inode
# (a refresh must never stamp disk state over unwritten local changes).
# That makes the dirty flag load-bearing in a way a
# single-node filesystem's is not -- an inode left dirty is an inode
# that cannot see a peer's changes.
#
# chmod, chown, utimes, truncate and punch-hole all persisted their
# record by calling cetrafs_write_vfs_inode() directly, which writes but
# does NOT clear the dirty state (only the VFS's sync_inode_metadata()
# does, and it ends at the same writer). So every one of them left the
# inode dirty with nothing actually unwritten, blocking cross-node
# refreshes of it until the VFS's own writeback came round -- on an
# inode that had just been modified, i.e. exactly one under contention.
#
# The observable: with the inode dirty, a change made to the record
# behind the mount is invisible; with it clean, the next lookup sees it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dirtyop)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dirtyop)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# After <op>, poke the record's permission bits behind the mount. A
# clean inode refreshes and stat reports the poked mode; a dirty one
# refuses the refresh (the dirty-inode guard) and keeps serving the cached value.
#
# The MODE is the right observable here and nlink is not: nlink==0
# refusal sits ahead of the dirty guard in cetrafs_apply_raw_to_vfs_inode(),
# so it fires either way and proves nothing about dirtiness. Using nlink
# would have passed against the broken build.
check_refresh_after() { # <name> <description> <command...>
    local name="$1" desc="$2"
    shift 2
    local ino got
    : >"$MNT/$name"
    ino="$(stat -c '%i' "$MNT/$name")"
    sync
    "$@" >/dev/null 2>&1 || true
    "$POKE" "$IMG" setmode "$ino" 0100707 >/dev/null 2>&1
    got="$(stat -c '%a' "$MNT/$name")"
    if [ "$got" = "707" ]; then
        pass "$desc leaves the inode clean, so a peer's change is still seen"
    else
        fail "$desc left the inode dirty: the record now says 707, this node still reports $got"
    fi
}

log "a metadata operation must leave the inode refreshable"
check_refresh_after chmodded "chmod" chmod 600 "$MNT/chmodded"
check_refresh_after chowned "chown" chown 3:4 "$MNT/chowned"
check_refresh_after touched "utimes" touch -d '2003-04-05 06:07:08' "$MNT/touched"
check_refresh_after grown "truncate (grow)" truncate -s 8192 "$MNT/grown"

# A shrink and a punch need a file with blocks first.
dd if=/dev/zero of="$MNT/shrunk" bs=4096 count=8 status=none
SH_INO="$(stat -c '%i' "$MNT/shrunk")"
sync
truncate -s 4096 "$MNT/shrunk"
"$POKE" "$IMG" setmode "$SH_INO" 0100707 >/dev/null 2>&1
[ "$(stat -c '%a' "$MNT/shrunk")" = "707" ] &&
    pass "truncate (shrink) leaves the inode clean" ||
    fail "truncate (shrink) left the inode dirty: this node still reports $(stat -c '%a' "$MNT/shrunk")"

dd if=/dev/zero of="$MNT/punched" bs=4096 count=8 status=none
PU_INO="$(stat -c '%i' "$MNT/punched")"
sync
fallocate -p -o 4096 -l 8192 "$MNT/punched" 2>/dev/null || fail "setup: punch hole failed"
"$POKE" "$IMG" setmode "$PU_INO" 0100707 >/dev/null 2>&1
[ "$(stat -c '%a' "$MNT/punched")" = "707" ] &&
    pass "punch hole leaves the inode clean" ||
    fail "punch hole left the inode dirty: this node still reports $(stat -c '%a' "$MNT/punched")"

log "and the operations themselves still do what they say"
[ "$(stat -c '%u:%g' "$MNT/chowned")" = "3:4" ] && pass "chown took effect" || fail "chown did not take effect"
[ "$(stat -c '%s' "$MNT/grown")" = "8192" ] && pass "truncate grew the file" || fail "truncate did not grow the file"
[ "$(stat -c '%s' "$MNT/shrunk")" = "4096" ] && pass "truncate shrank the file" || fail "truncate did not shrink the file"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%u:%g' "$MNT/chowned")" = "3:4" ] && pass "the owner is on disk after a remount" ||
    fail "the owner did not persist"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
