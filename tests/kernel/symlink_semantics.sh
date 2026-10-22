#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# symlinks: the ordinary semantics, and what a failed one leaves behind
#
# The interesting path is the failure one. By the time page_symlink()
# has written the target text, a symlink owns an inode, a directory
# entry AND a data block -- and the unwind called cetrafs_free_inode()
# and then iput(). That frees the inode NUMBER but not the block:
# eviction only frees an inode's blocks once its link count reaches
# zero, and the record had been stamped nlink = 1. So the block leaked
# and the number went back to the allocator while a record describing a
# live file still named that block -- which is exactly how the
# eviction fix describes a leak becoming untraceable, since
# the next file to reuse the number overwrites the only evidence.
#
# No input reaches that path, hence the symlink_fail_after_write param.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FAIL_PARAM=/sys/module/cetrafs/parameters/symlink_fail_after_write

IMG="$(ct_image 560 symlink)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt symlink)"
REF="$(ct_mnt symlinkref)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "ordinary symlink semantics, against tmpfs"
build() {
    local r="$1"
    echo payload >"$r/real"
    ln -s real "$r/rel"
    ln -s /absolute/path "$r/abs"
    mkdir "$r/sub"
    ln -s ../real "$r/sub/up"
    ln -s nowhere "$r/dangling"
    ln -s "$(printf 'x%.0s' $(seq 1 4000))" "$r/long"
}
build "$MNT"
build "$REF"
for n in rel abs sub/up dangling long; do
    got="$(readlink "$MNT/$n")"
    want="$(readlink "$REF/$n")"
    [ "$got" = "$want" ] && pass "readlink '$n' matches tmpfs (${#got} chars)" ||
        fail "readlink '$n': cetrafs '${got:0:40}', tmpfs '${want:0:40}'"
done
[ "$(cat "$MNT/rel")" = "payload" ] && pass "a relative symlink resolves" || fail "a relative symlink does not resolve"
[ "$(cat "$MNT/sub/up")" = "payload" ] && pass "a symlink with '..' resolves" || fail "'../real' does not resolve"
cat "$MNT/dangling" 2>/dev/null && fail "a dangling symlink resolved" || pass "a dangling symlink gives ENOENT"
[ "$(stat -c '%s' "$MNT/long")" = "$(stat -c '%s' "$REF/long")" ] &&
    pass "a 4000-character target reports the same size as tmpfs" ||
    fail "size: cetrafs $(stat -c '%s' "$MNT/long"), tmpfs $(stat -c '%s' "$REF/long")"

log "a symlink survives a remount and reads back cold"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(readlink "$MNT/long")" = "$(readlink "$REF/long")" ] &&
    pass "the long target reads back identically after a remount" ||
    fail "the long target changed across a remount"
[ "$(cat "$MNT/rel")" = "payload" ] && pass "and still resolves" || fail "it no longer resolves"

log "a symlink's block comes back when it is removed"
avail() { df --output=avail "$MNT" | tail -1; }
FREE_BEFORE="$(avail)"
ln -s /some/where "$MNT/tmp1"
[ "$(avail)" -lt "$FREE_BEFORE" ] || fail "setup: creating a symlink consumed no space"
rm "$MNT/tmp1"
sync
[ "$(avail)" = "$FREE_BEFORE" ] && pass "removing a symlink returns its target block" ||
    fail "free space is $(avail), was $FREE_BEFORE before the symlink existed"

log "a symlink that fails after writing its target leaves nothing behind"
if [ ! -w "$FAIL_PARAM" ]; then
    skip "symlink_fail_after_write is missing; the unwind cannot be reached"
else
    FREE_BEFORE="$(avail)"
    echo 1 >"$FAIL_PARAM"
    ln -s /target "$MNT/doomed" 2>/dev/null && fail "the injected failure did not fail the symlink" ||
        pass "the symlink failed as instructed"
    echo 0 >"$FAIL_PARAM"
    [ -e "$MNT/doomed" ] || [ -L "$MNT/doomed" ] &&
        fail "the failed symlink left its name behind" ||
        pass "the failed symlink left no name"
    sync
    [ "$(avail)" = "$FREE_BEFORE" ] &&
        pass "the failed symlink gave back its target block" ||
        fail "free space is $(avail), was $FREE_BEFORE -- the target block leaked"
    ct_umount "$MNT"
    if ct_fsck "$DEV" >/dev/null 2>&1; then
        pass "fsck is clean after the failed symlink"
    else
        fail "the failed symlink left a fault: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
    fi
    ct_mount "$DEV" "$MNT"
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
