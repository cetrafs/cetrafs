#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkdir: link counts, '.' and '..', growth, and what a refusal leaves
#
# tmpfs is the reference for everything a POSIX filesystem has to get
# right here, so the assertions compare the two rather than hardcoding
# numbers: a directory's nlink is 2 plus its subdirectory count at every
# level, '.' and '..' resolve to the right inodes, and removing a
# subdirectory gives the parent's count back.
#
# The rest is what mkdir does that create does not -- it allocates a
# data block and writes '.'/'..' into it before the record exists, and
# bumps the PARENT's nlink -- so the refusal paths have more to unwind.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 mkdir)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mkdir)"
REF="$(ct_mnt mkdirref)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

build() {
    local r="$1"
    mkdir "$r/p"
    # 200 subdirectories forces the parent past its four inline extents
    # into a depth-1 external leaf, which is a different walk.
    for i in $(seq 1 200); do mkdir "$r/p/d$i"; done
    : >"$r/p/afile"
    mkdir -p "$r/deep/a/b/c/d/e/f/g/h/i/j"
}
build "$MNT"
build "$REF"

cmp_stat() { # <relative path> <format> <what>
    local got want
    got="$(stat -c "$2" "$MNT/$1")"
    want="$(stat -c "$2" "$REF/$1")"
    [ "$got" = "$want" ] && pass "$3: $got (matches tmpfs)" ||
        fail "$3: cetrafs says '$got', tmpfs says '$want'"
}

log "link counts match tmpfs at every level"
cmp_stat p '%h' "a directory with 200 subdirectories and a file"
cmp_stat p/d1 '%h' "an empty subdirectory"
cmp_stat deep '%h' "a directory with one subdirectory"
cmp_stat deep/a/b/c/d/e/f/g/h/i/j '%h' "the deepest directory"
[ "$(stat -c '%h' "$MNT")" = "$(stat -c '%h' "$REF")" ] &&
    pass "the mount root's link count matches tmpfs" ||
    fail "root nlink: cetrafs $(stat -c '%h' "$MNT"), tmpfs $(stat -c '%h' "$REF")"

log "'.' and '..' point where they should"
[ "$(stat -c '%i' "$MNT/p/d7/.")" = "$(stat -c '%i' "$MNT/p/d7")" ] &&
    pass "'.' resolves to the directory itself" || fail "'.' does not resolve to the directory"
[ "$(stat -c '%i' "$MNT/p/d7/..")" = "$(stat -c '%i' "$MNT/p")" ] &&
    pass "'..' resolves to the parent" || fail "'..' does not resolve to the parent"
# The 200th subdirectory lives past the parent's first dirent block, so
# this also proves '..' is right for an entry the parent had to grow for.
[ "$(cd "$MNT/p/d200" && cd .. && pwd)" = "$MNT/p" ] &&
    pass "'..' is correct for a subdirectory in a grown parent's later block" ||
    fail "'..' from a late subdirectory lands elsewhere"

log "rmdir gives the link back"
BEFORE="$(stat -c '%h' "$MNT/p")"
rmdir "$MNT/p/d200"
AFTER="$(stat -c '%h' "$MNT/p")"
[ "$AFTER" = "$((BEFORE - 1))" ] && pass "removing a subdirectory drops the parent's nlink by one" ||
    fail "parent nlink went $BEFORE -> $AFTER"
rmdir "$MNT/p/d199"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%h' "$MNT/p")" = "$((BEFORE - 2))" ] &&
    pass "the link count is on disk, not just in core" ||
    fail "after a remount the parent's nlink is $(stat -c '%h' "$MNT/p"), expected $((BEFORE - 2))"

log "a grown ROOT directory is still structurally valid"
# Root grows past its inline extents like any other directory -- at
# about 58 names. fsck used to require eh_depth == 0 on root
# specifically, so from the 59th entry onward it reported "root extents
# header invalid" on a perfectly healthy filesystem, forever. A check
# that cries wolf is how people learn to ignore fsck.
for i in $(seq 1 120); do mkdir "$MNT/rootdir$i"; done
ct_umount "$MNT"
if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck is clean with a root directory that has spilled to depth 1"
else
    fail "fsck on a grown root: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
fi

log "a refusal leaves nothing behind"
IMG2="$(ct_image 560 mkdir2)"
DEV2="$(ct_loop "$IMG2")"
MNT2="$(ct_mnt mkdir2)"
ct_mkfs "$DEV2" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV2" "$MNT2"
i=0
while mkdir "$MNT2/d$i" 2>/dev/null; do i=$((i + 1)); done
[ "$i" -gt 0 ] && pass "filled the inode table with $i directories" || fail "could not create any directory"
mkdir "$MNT2/past-the-end" 2>/dev/null &&
    fail "mkdir succeeded with no inodes left" ||
    pass "mkdir with no free inode is refused"
ct_umount "$MNT2"
# The inode allocation happens BEFORE the data block and the entry, so a
# refusal anywhere later has to give all of it back.
if ct_fsck "$DEV2" >/dev/null 2>&1; then
    pass "fsck is clean after running the inode table out"
else
    fail "a refused mkdir leaked something: $(ct_fsck "$DEV2" 2>&1 | grep -i err | head -3)"
fi

ct_exit
