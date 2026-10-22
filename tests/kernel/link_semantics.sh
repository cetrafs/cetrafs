#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# hardlinks, and the directory-entry type that readdir hands out
#
# A dirent carries a file_type that readdir reports as d_type, and a
# great deal of tooling trusts d_type rather than calling stat --
# `find -type l`, fts, rsync, tar. Two sites hardcoded it:
# cetrafs_link_locked() always wrote CETRAFS_FT_REG, and
# cetrafs_rename_locked() derived only DIR-or-REG. So hardlinking or
# renaming a SYMLINK silently retyped its entry to a regular file, and
# `find -type l` stopped seeing it -- while `ls -F`, which stats, looked
# perfectly correct.
#
# tmpfs is the reference throughout.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 link)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt link)"
REF="$(ct_mnt linkref)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

build() {
    local r="$1"
    ln -s /some/target "$r/sym"
    ln "$r/sym" "$r/sym-hardlink"
    ln -s /other "$r/sym2"
    mv "$r/sym2" "$r/sym2-renamed"
    echo content >"$r/reg"
    ln "$r/reg" "$r/reg2"
    mkdir "$r/d"
    mv "$r/d" "$r/d-renamed"
}
build "$MNT"
build "$REF"

log "readdir reports the right d_type, including after link and rename"
# find -type uses d_type from readdir and only falls back to stat when
# the filesystem says DT_UNKNOWN, so this is the assertion that sees the
# dirent's own type rather than the inode's.
for n in sym sym-hardlink sym2-renamed reg reg2; do
    got="$(find "$MNT" -maxdepth 1 -name "$n" -type l | wc -l)"
    want="$(find "$REF" -maxdepth 1 -name "$n" -type l | wc -l)"
    [ "$got" = "$want" ] && pass "find -type l agrees with tmpfs on '$n'" ||
        fail "'$n': cetrafs -type l matched $got, tmpfs matched $want"
done
got="$(find "$MNT" -maxdepth 1 -name d-renamed -type d | wc -l)"
[ "$got" = "1" ] && pass "a renamed directory still reports as a directory" ||
    fail "a renamed directory is no longer -type d"
# And the type survives a remount: it lives in the dirent, not in core.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(find "$MNT" -maxdepth 1 -name sym-hardlink -type l | wc -l)" = "1" ] &&
    pass "the entry's type is on disk, not just in core" ||
    fail "after a remount the hardlinked symlink is no longer -type l"

log "hardlink semantics match tmpfs"
cmp_stat() {
    local got want
    got="$(stat -c "$2" "$MNT/$1")"
    want="$(stat -c "$2" "$REF/$1")"
    [ "$got" = "$want" ] && pass "$3: $got (matches tmpfs)" ||
        fail "$3: cetrafs '$got', tmpfs '$want'"
}
cmp_stat reg '%h' "a file with two names has nlink 2"
[ "$(stat -c '%i' "$MNT/reg")" = "$(stat -c '%i' "$MNT/reg2")" ] &&
    pass "both names resolve to the same inode" || fail "the two names have different inodes"
[ "$(cat "$MNT/reg2")" = "content" ] && pass "the second name reads the same content" ||
    fail "the second name reads '$(cat "$MNT/reg2")'"
[ "$(readlink "$MNT/sym-hardlink")" = "/some/target" ] &&
    pass "a hardlinked symlink still reads as a symlink" ||
    fail "readlink of the hardlinked symlink gave '$(readlink "$MNT/sym-hardlink")'"

log "unlinking one name leaves the other intact"
rm "$MNT/reg"
[ "$(cat "$MNT/reg2")" = "content" ] && pass "the surviving name still reads correctly" ||
    fail "the surviving name is broken"
[ "$(stat -c '%h' "$MNT/reg2")" = "1" ] && pass "nlink dropped to 1" ||
    fail "nlink is $(stat -c '%h' "$MNT/reg2")"

log "link updates the target's ctime on disk"
: >"$MNT/ct"
sync
CT_BEFORE="$(stat -c '%Z' "$MNT/ct")"
sleep 1.1
ln "$MNT/ct" "$MNT/ct-link"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%Z' "$MNT/ct")" -gt "$CT_BEFORE" ] &&
    pass "the target's ctime advanced on disk" ||
    fail "the target's on-disk ctime did not move"

log "the refusals"
mkdir "$MNT/adir"
ln "$MNT/adir" "$MNT/adir-link" 2>/dev/null && fail "a directory was hardlinked" ||
    pass "hardlinking a directory is refused"
ln "$MNT/ct" "$MNT/ct-link" 2>/dev/null && fail "link over an existing name succeeded" ||
    pass "link onto an existing name is refused"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
