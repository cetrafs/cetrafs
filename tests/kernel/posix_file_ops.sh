#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the ordinary POSIX surface: create, unlink, truncate, rename, link, symlink, xattr, statfs
#
# One volume, one mount, the full sequence a user actually performs --
# each step verified both immediately and again after a remount, because
# "it worked until umount" is a failure mode this filesystem has really
# had (.writepages missing meant dirtied pages never reached disk).
#
# Also covers extent growth across block boundaries, the spill into an
# external leaf at the 5th extent, truncate shrink/grow/zero, rename
# replace semantics and '..' fixup, hardlink nlink accounting, and
# statfs reporting live counts rather than mkfs-time ones.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# The standard small volume: 1 ZG, one 512 MiB BG, no journal, 1024 inodes.
IMG="$(ct_image 560 main)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt main)"
ct_mkfs_small "$LOOPDEV" >/dev/null
ct_track mnt "$MNT"   # so an abort mid-suite still unmounts
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"


check_created_file() {
    local when="$1"
    if [ -f "$MNT/hello" ]; then
        pass "$when: created file is visible"
    else
        fail "$when: created file is missing"
        return
    fi

    local mode
    mode="$(stat -c '%a' "$MNT/hello")"
    [ "$mode" = "644" ] && pass "$when: file mode is 0644" || fail "$when: file mode is $mode, expected 644"

    local nlink
    nlink="$(stat -c '%h' "$MNT/hello")"
    [ "$nlink" = "1" ] && pass "$when: file nlink is 1" || fail "$when: file nlink is $nlink, expected 1"

    local type
    type="$(stat -c '%F' "$MNT/hello")"
    [ "$type" = "regular empty file" ] && pass "$when: file is an empty regular file" ||
        fail "$when: file reports as '$type', expected 'regular empty file'"

}

check_created_dir() {
    local when="$1"
    if [ -d "$MNT/sub" ]; then
        pass "$when: created subdirectory is visible"
    else
        fail "$when: created subdirectory is missing"
        return
    fi

    local mode
    mode="$(stat -c '%a' "$MNT/sub")"
    [ "$mode" = "755" ] && pass "$when: subdirectory mode is 0755" || fail "$when: subdirectory mode is $mode, expected 755"

    local nlink
    nlink="$(stat -c '%h' "$MNT/sub")"
    [ "$nlink" = "2" ] && pass "$when: subdirectory nlink is 2" || fail "$when: subdirectory nlink is $nlink, expected 2"

    local type
    type="$(stat -c '%F' "$MNT/sub")"
    [ "$type" = "directory" ] && pass "$when: subdirectory reports as a directory" ||
        fail "$when: subdirectory reports as '$type', expected directory"

    local ls_out
    ls_out="$(ls -a "$MNT/sub" | sort)"
    local expected
    expected="$(printf '.\n..\n' | sort)"
    [ "$ls_out" = "$expected" ] && pass "$when: ls inside subdirectory shows only '.' and '..'" ||
        fail "$when: ls inside subdirectory shows unexpected entries: $ls_out"
}

check_root_listing() {
    local when="$1"
    local nlink
    nlink="$(stat -c '%h' "$MNT")"
    [ "$nlink" = "3" ] && pass "$when: root nlink is 3 (2 + one subdirectory)" ||
        fail "$when: root nlink is $nlink, expected 3"

    local ls_out
    ls_out="$(ls -a "$MNT" | sort)"
    local expected
    expected="$(printf '.\n..\nhello\nsub\n' | sort)"
    [ "$ls_out" = "$expected" ] && pass "$when: ls shows '.', '..', 'hello' and 'sub'" ||
        fail "$when: ls shows unexpected entries: $ls_out"
}

log "creating a file"
touch "$MNT/hello"
check_created_file "post-create"

log "creating a subdirectory"
mkdir "$MNT/sub"
check_created_dir "post-create"
check_root_listing "post-create"

log "remounting to verify the new file/subdirectory persisted to disk"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1
check_created_file "post-remount"
check_created_dir "post-remount"
check_root_listing "post-remount"

log "unlinking the file"
rm "$MNT/hello"
if [ -e "$MNT/hello" ]; then
    fail "post-unlink: file still visible after rm"
else
    pass "post-unlink: file no longer visible"
fi

NLINK="$(stat -c '%h' "$MNT")"
[ "$NLINK" = "3" ] && pass "post-unlink: root nlink unchanged at 3 (removing a file doesn't affect dir nlink)" ||
    fail "post-unlink: root nlink is $NLINK, expected 3"

LS_OUT="$(ls -a "$MNT" | sort)"
EXPECTED="$(printf '.\n..\nsub\n' | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "post-unlink: ls shows only '.', '..' and 'sub'" ||
    fail "post-unlink: ls shows unexpected entries: $LS_OUT"

log "remounting to verify the unlink persisted to disk"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

if [ -e "$MNT/hello" ]; then
    fail "post-unlink-remount: file still visible after remount"
else
    pass "post-unlink-remount: file still gone after remount"
fi
check_created_dir "post-unlink-remount"
NLINK="$(stat -c '%h' "$MNT")"
[ "$NLINK" = "3" ] && pass "post-unlink-remount: root nlink still 3" ||
    fail "post-unlink-remount: root nlink is $NLINK, expected 3"

log "attempting to rmdir a non-empty directory"
touch "$MNT/sub/inside"
if rmdir "$MNT/sub" 2>/dev/null; then
    fail "rmdir of a non-empty directory unexpectedly succeeded"
else
    pass "rmdir of a non-empty directory correctly fails (ENOTEMPTY)"
fi
rm "$MNT/sub/inside"

log "removing the subdirectory"
rmdir "$MNT/sub"
if [ -e "$MNT/sub" ]; then
    fail "post-rmdir: subdirectory still visible after rmdir"
else
    pass "post-rmdir: subdirectory no longer visible"
fi

NLINK="$(stat -c '%h' "$MNT")"
[ "$NLINK" = "2" ] && pass "post-rmdir: root nlink back to 2" ||
    fail "post-rmdir: root nlink is $NLINK, expected 2"

LS_OUT="$(ls -a "$MNT" | sort)"
EXPECTED="$(printf '.\n..\n' | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "post-rmdir: ls shows only '.' and '..'" ||
    fail "post-rmdir: ls shows unexpected entries: $LS_OUT"

log "remounting to verify the rmdir persisted to disk"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

if [ -e "$MNT/sub" ]; then
    fail "post-rmdir-remount: subdirectory still visible after remount"
else
    pass "post-rmdir-remount: subdirectory still gone after remount"
fi
NLINK="$(stat -c '%h' "$MNT")"
[ "$NLINK" = "2" ] && pass "post-rmdir-remount: root nlink still 2" ||
    fail "post-rmdir-remount: root nlink is $NLINK, expected 2"

log "writing and reading back file data (single block)"
printf 'hello cetrafs data path\n' >"$MNT/data"
GOT="$(cat "$MNT/data")"
[ "$GOT" = "hello cetrafs data path" ] && pass "post-write: read back matches what was written" ||
    fail "post-write: read back '$GOT', expected 'hello cetrafs data path'"

SIZE="$(stat -c '%s' "$MNT/data")"
[ "$SIZE" = "24" ] && pass "post-write: file size is 24 bytes" || fail "post-write: file size is $SIZE, expected 24"

log "writing a multi-block file (exercises extent growth across block boundaries)"
dd if=/dev/urandom of=/tmp/cetrafs-test-src bs=4096 count=3 status=none
cp /tmp/cetrafs-test-src "$MNT/big"
SRC_SUM="$(sha256sum /tmp/cetrafs-test-src | cut -d' ' -f1)"
DST_SUM="$(sha256sum "$MNT/big" | cut -d' ' -f1)"
[ "$SRC_SUM" = "$DST_SUM" ] && pass "post-write: multi-block file content matches (same mount)" ||
    fail "post-write: multi-block file checksum mismatch (same mount)"

log "writing a fragmented 5-block file (forces a 5th extent -> external leaf block)"
rm -f /tmp/cetrafs-frag-src
for i in 0 1 2 3 4; do
    dd if=/dev/urandom of=/tmp/cetrafs-frag-block bs=4096 count=1 status=none
    cat /tmp/cetrafs-frag-block >>/tmp/cetrafs-frag-src
    dd if=/tmp/cetrafs-frag-block of="$MNT/frag" bs=4096 seek="$i" count=1 conv=notrunc status=none
    # interleave an unrelated 1-block write so each of frag's blocks lands
    # on a non-contiguous LBA, instead of being coalesced into one extent
    [ "$i" -lt 4 ] && printf x >"$MNT/filler$i"
done
rm -f /tmp/cetrafs-frag-block
FRAG_SRC_SUM="$(sha256sum /tmp/cetrafs-frag-src | cut -d' ' -f1)"
FRAG_DST_SUM="$(sha256sum "$MNT/frag" | cut -d' ' -f1)"
[ "$FRAG_SRC_SUM" = "$FRAG_DST_SUM" ] && pass "post-write: fragmented 5-block file content matches (same mount)" ||
    fail "post-write: fragmented 5-block file checksum mismatch (same mount)"

log "remounting to verify written data persisted to disk"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

GOT="$(cat "$MNT/data")"
[ "$GOT" = "hello cetrafs data path" ] && pass "post-write-remount: small file content persisted" ||
    fail "post-write-remount: read back '$GOT', expected 'hello cetrafs data path'"

DST_SUM="$(sha256sum "$MNT/big" | cut -d' ' -f1)"
[ "$SRC_SUM" = "$DST_SUM" ] && pass "post-write-remount: multi-block file content persisted" ||
    fail "post-write-remount: multi-block file checksum mismatch after remount"

FRAG_DST_SUM="$(sha256sum "$MNT/frag" | cut -d' ' -f1)"
[ "$FRAG_SRC_SUM" = "$FRAG_DST_SUM" ] && pass "post-write-remount: fragmented 5-block (external-leaf) file content persisted" ||
    fail "post-write-remount: fragmented 5-block file checksum mismatch after remount"

log "shrinking a multi-block file with truncate (frees trailing blocks)"
truncate -s 6000 "$MNT/big"
SIZE="$(stat -c '%s' "$MNT/big")"
[ "$SIZE" = "6000" ] && pass "post-truncate-shrink: file size is 6000 bytes" ||
    fail "post-truncate-shrink: file size is $SIZE, expected 6000"
head -c 6000 /tmp/cetrafs-test-src >/tmp/cetrafs-test-src-6000
DST_SUM="$(sha256sum "$MNT/big" | cut -d' ' -f1)"
EXPECT_SUM="$(sha256sum /tmp/cetrafs-test-src-6000 | cut -d' ' -f1)"
[ "$DST_SUM" = "$EXPECT_SUM" ] && pass "post-truncate-shrink: remaining content matches the original's first 6000 bytes" ||
    fail "post-truncate-shrink: content mismatch after shrinking"

log "growing a file with truncate (sparse hole, then writing into it)"
truncate -s 10000 "$MNT/data"
SIZE="$(stat -c '%s' "$MNT/data")"
[ "$SIZE" = "10000" ] && pass "post-truncate-grow: file size is 10000 bytes" ||
    fail "post-truncate-grow: file size is $SIZE, expected 10000"
HOLE_BYTES="$(dd if="$MNT/data" bs=1 skip=100 count=16 status=none | od -An -tx1 | tr -d ' \n')"
[ "$HOLE_BYTES" = "00000000000000000000000000000000" ] && pass "post-truncate-grow: hole reads back as zero" ||
    fail "post-truncate-grow: hole bytes were '$HOLE_BYTES', expected all zero"
printf 'tail-write' | dd of="$MNT/data" bs=1 seek=9000 conv=notrunc status=none
TAIL="$(dd if="$MNT/data" bs=1 skip=9000 count=10 status=none)"
[ "$TAIL" = "tail-write" ] && pass "post-truncate-grow: write into the hole reads back correctly" ||
    fail "post-truncate-grow: tail write read back '$TAIL', expected 'tail-write'"

log "truncating the fragmented (external-leaf) file to zero"
truncate -s 0 "$MNT/frag"
SIZE="$(stat -c '%s' "$MNT/frag")"
[ "$SIZE" = "0" ] && pass "post-truncate-zero: fragmented file size is 0" ||
    fail "post-truncate-zero: fragmented file size is $SIZE, expected 0"

log "writing a second fragmented file and unlinking it directly (exercises freeing an external leaf block via unlink)"
rm -f /tmp/cetrafs-frag2-src
for i in 0 1 2 3 4; do
    dd if=/dev/urandom of=/tmp/cetrafs-frag2-block bs=4096 count=1 status=none
    cat /tmp/cetrafs-frag2-block >>/tmp/cetrafs-frag2-src
    dd if=/tmp/cetrafs-frag2-block of="$MNT/frag2" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 4 ] && printf x >"$MNT/filler2-$i"
done
rm -f /tmp/cetrafs-frag2-block /tmp/cetrafs-frag2-src
rm "$MNT/frag2"
if [ -e "$MNT/frag2" ]; then
    fail "post-unlink-frag: fragmented file still visible after rm"
else
    pass "post-unlink-frag: fragmented (external-leaf) file no longer visible"
fi

log "remounting to verify truncate (shrink/grow/zero) and the unlink survived"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

SIZE="$(stat -c '%s' "$MNT/big")"
DST_SUM="$(sha256sum "$MNT/big" | cut -d' ' -f1)"
EXPECT_SUM="$(sha256sum /tmp/cetrafs-test-src-6000 | cut -d' ' -f1)"
[ "$SIZE" = "6000" ] && [ "$DST_SUM" = "$EXPECT_SUM" ] && pass "post-truncate-remount: shrunk file size and content persisted" ||
    fail "post-truncate-remount: shrunk file size=$SIZE (expected 6000) or content mismatch"

SIZE="$(stat -c '%s' "$MNT/data")"
TAIL="$(dd if="$MNT/data" bs=1 skip=9000 count=10 status=none)"
[ "$SIZE" = "10000" ] && [ "$TAIL" = "tail-write" ] && pass "post-truncate-remount: grown file size and tail write persisted" ||
    fail "post-truncate-remount: grown file size=$SIZE (expected 10000) or tail='$TAIL' (expected 'tail-write')"

SIZE="$(stat -c '%s' "$MNT/frag")"
[ "$SIZE" = "0" ] && pass "post-truncate-remount: zero-truncated fragmented file still 0 bytes" ||
    fail "post-truncate-remount: fragmented file size is $SIZE, expected 0"

if [ -e "$MNT/frag2" ]; then
    fail "post-truncate-remount: unlinked fragmented file reappeared after remount"
else
    pass "post-truncate-remount: unlinked fragmented file still gone after remount"
fi

rm -f /tmp/cetrafs-test-src /tmp/cetrafs-test-src-6000 /tmp/cetrafs-frag-src

log "renaming a file within the same directory"
mv "$MNT/data" "$MNT/data-renamed"
if [ ! -e "$MNT/data" ] && [ -e "$MNT/data-renamed" ]; then
    pass "post-rename: old name gone, new name present"
else
    fail "post-rename: old/new name state wrong after same-dir rename"
fi
GOT="$(dd if="$MNT/data-renamed" bs=1 skip=9000 count=10 status=none)"
[ "$GOT" = "tail-write" ] && pass "post-rename: content intact after same-dir rename" ||
    fail "post-rename: content wrong after same-dir rename: '$GOT'"

log "renaming a file across directories"
mkdir "$MNT/destdir"
mv "$MNT/data-renamed" "$MNT/destdir/moved-file"
if [ ! -e "$MNT/data-renamed" ] && [ -e "$MNT/destdir/moved-file" ]; then
    pass "post-rename: file moved across directories"
else
    fail "post-rename: cross-directory file move didn't take effect"
fi

log "renaming a directory across parents (checks '..' gets fixed up)"
mkdir "$MNT/movedir"
touch "$MNT/movedir/inside-file"
mv "$MNT/movedir" "$MNT/destdir/movedir"
if [ ! -e "$MNT/movedir" ] && [ -d "$MNT/destdir/movedir" ] && [ -e "$MNT/destdir/movedir/inside-file" ]; then
    pass "post-rename: directory moved across parents, contents intact"
else
    fail "post-rename: directory move across parents didn't take effect"
fi
DESTDIR_INO="$(stat -c '%i' "$MNT/destdir")"
DOTDOT_INO="$(stat -c '%i' "$MNT/destdir/movedir/..")"
[ "$DESTDIR_INO" = "$DOTDOT_INO" ] && pass "post-rename: moved directory's '..' now points at its new parent" ||
    fail "post-rename: moved directory's '..' is ino $DOTDOT_INO, expected destdir's ino $DESTDIR_INO"

ROOT_NLINK="$(stat -c '%h' "$MNT")"
[ "$ROOT_NLINK" = "3" ] && pass "post-rename: root nlink is 3 (2 base + 'destdir', having lost 'movedir')" ||
    fail "post-rename: root nlink is $ROOT_NLINK, expected 3"
DESTDIR_NLINK="$(stat -c '%h' "$MNT/destdir")"
[ "$DESTDIR_NLINK" = "3" ] && pass "post-rename: destdir nlink is 3 (2 + gained 'movedir')" ||
    fail "post-rename: destdir nlink is $DESTDIR_NLINK, expected 3"

log "renaming a file onto an existing file (replace semantics)"
printf 'replacement content' >"$MNT/replacement-src"
printf 'original content, to be replaced' >"$MNT/replacement-dst"
mv "$MNT/replacement-src" "$MNT/replacement-dst"
if [ ! -e "$MNT/replacement-src" ] && [ -e "$MNT/replacement-dst" ]; then
    GOT="$(cat "$MNT/replacement-dst")"
    [ "$GOT" = "replacement content" ] && pass "post-rename: rename-over-existing-file replaced content correctly" ||
        fail "post-rename: rename-over-existing-file has wrong content: '$GOT'"
else
    fail "post-rename: rename-over-existing-file didn't take effect"
fi

log "remounting to verify all renames persisted to disk"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

if [ ! -e "$MNT/data" ] && [ ! -e "$MNT/data-renamed" ] && [ -e "$MNT/destdir/moved-file" ]; then
    pass "post-rename-remount: cross-directory file move persisted"
else
    fail "post-rename-remount: cross-directory file move did not persist"
fi
if [ -d "$MNT/destdir/movedir" ] && [ -e "$MNT/destdir/movedir/inside-file" ]; then
    pass "post-rename-remount: directory move across parents persisted"
else
    fail "post-rename-remount: directory move across parents did not persist"
fi
DESTDIR_INO="$(stat -c '%i' "$MNT/destdir")"
DOTDOT_INO="$(stat -c '%i' "$MNT/destdir/movedir/..")"
[ "$DESTDIR_INO" = "$DOTDOT_INO" ] && pass "post-rename-remount: moved directory's '..' still points at its new parent" ||
    fail "post-rename-remount: moved directory's '..' is ino $DOTDOT_INO, expected destdir's ino $DESTDIR_INO"
GOT="$(cat "$MNT/replacement-dst" 2>/dev/null)"
[ "$GOT" = "replacement content" ] && pass "post-rename-remount: rename-over-existing-file content persisted" ||
    fail "post-rename-remount: rename-over-existing-file content is '$GOT' after remount"

log "creating a hardlink"
printf 'shared content' >"$MNT/linktarget"
ln "$MNT/linktarget" "$MNT/linkname"

TARGET_INO="$(stat -c '%i' "$MNT/linktarget")"
LINK_INO="$(stat -c '%i' "$MNT/linkname")"
[ "$TARGET_INO" = "$LINK_INO" ] && pass "post-link: hardlink shares the same inode number" ||
    fail "post-link: linktarget ino=$TARGET_INO, linkname ino=$LINK_INO, expected equal"

TARGET_NLINK="$(stat -c '%h' "$MNT/linktarget")"
[ "$TARGET_NLINK" = "2" ] && pass "post-link: nlink is 2 after creating the hardlink" ||
    fail "post-link: nlink is $TARGET_NLINK, expected 2"

GOT="$(cat "$MNT/linkname")"
[ "$GOT" = "shared content" ] && pass "post-link: content visible through the new name" ||
    fail "post-link: content via linkname is '$GOT', expected 'shared content'"

printf 'updated via linkname' >"$MNT/linkname"
GOT="$(cat "$MNT/linktarget")"
[ "$GOT" = "updated via linkname" ] && pass "post-link: write through one name visible through the other (same inode)" ||
    fail "post-link: write through linkname not visible via linktarget: '$GOT'"

mkdir "$MNT/linkdirtest"
if ln "$MNT/linkdirtest" "$MNT/linkdirtest2" 2>/dev/null; then
    fail "post-link: hardlinking a directory unexpectedly succeeded"
else
    pass "post-link: hardlinking a directory correctly fails (EPERM)"
fi

log "remounting to verify the hardlink persisted"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

TARGET_INO="$(stat -c '%i' "$MNT/linktarget")"
LINK_INO="$(stat -c '%i' "$MNT/linkname")"
TARGET_NLINK="$(stat -c '%h' "$MNT/linktarget")"
GOT="$(cat "$MNT/linktarget")"
if [ "$TARGET_INO" = "$LINK_INO" ] && [ "$TARGET_NLINK" = "2" ] && [ "$GOT" = "updated via linkname" ]; then
    pass "post-link-remount: hardlink (shared inode, nlink, content) persisted"
else
    fail "post-link-remount: ino match=$( [ "$TARGET_INO" = "$LINK_INO" ] && echo yes || echo no ), nlink=$TARGET_NLINK, content='$GOT'"
fi

log "unlinking one of the two hardlinked names"
rm "$MNT/linktarget"
if [ -e "$MNT/linktarget" ]; then
    fail "post-unlink-one: linktarget still visible after rm"
else
    pass "post-unlink-one: linktarget no longer visible"
fi
LINK_NLINK="$(stat -c '%h' "$MNT/linkname")"
[ "$LINK_NLINK" = "1" ] && pass "post-unlink-one: remaining name's nlink dropped to 1" ||
    fail "post-unlink-one: remaining name's nlink is $LINK_NLINK, expected 1"
GOT="$(cat "$MNT/linkname")"
[ "$GOT" = "updated via linkname" ] && pass "post-unlink-one: remaining name's content intact" ||
    fail "post-unlink-one: remaining name's content is '$GOT', expected 'updated via linkname'"

log "remounting to verify the single remaining name survived"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

if [ ! -e "$MNT/linktarget" ] && [ -e "$MNT/linkname" ]; then
    pass "post-unlink-one-remount: only the remaining name exists"
else
    fail "post-unlink-one-remount: unexpected existence state for linktarget/linkname"
fi
LINK_NLINK="$(stat -c '%h' "$MNT/linkname")"
[ "$LINK_NLINK" = "1" ] && pass "post-unlink-one-remount: nlink still 1" ||
    fail "post-unlink-one-remount: nlink is $LINK_NLINK, expected 1"

log "creating a symlink"
ln -s linkname "$MNT/symlinkname"

TYPE="$(stat -c '%F' "$MNT/symlinkname")"
[ "$TYPE" = "symbolic link" ] && pass "post-symlink: reports as a symbolic link" ||
    fail "post-symlink: reports as '$TYPE', expected 'symbolic link'"

TARGET="$(readlink "$MNT/symlinkname")"
[ "$TARGET" = "linkname" ] && pass "post-symlink: readlink returns the target" ||
    fail "post-symlink: readlink returned '$TARGET', expected 'linkname'"

GOT="$(cat "$MNT/symlinkname")"
[ "$GOT" = "updated via linkname" ] && pass "post-symlink: following the symlink reads the target file's content" ||
    fail "post-symlink: content via symlink is '$GOT', expected 'updated via linkname'"

LONG_TARGET="$(printf 'x%.0s' $(seq 1 4096))"
if ln -s "$LONG_TARGET" "$MNT/symlink-too-long" 2>/dev/null; then
    fail "post-symlink: creating an oversized (>= PATH_MAX) symlink target unexpectedly succeeded"
else
    pass "post-symlink: creating an oversized symlink target correctly fails"
fi

log "remounting to verify the symlink persisted"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

TYPE="$(stat -c '%F' "$MNT/symlinkname")"
TARGET="$(readlink "$MNT/symlinkname")"
GOT="$(cat "$MNT/symlinkname")"
if [ "$TYPE" = "symbolic link" ] && [ "$TARGET" = "linkname" ] && [ "$GOT" = "updated via linkname" ]; then
    pass "post-symlink-remount: symlink type/target/content all persisted"
else
    fail "post-symlink-remount: type='$TYPE', target='$TARGET', content='$GOT'"
fi

log "unlinking the symlink"
rm "$MNT/symlinkname"
if [ -e "$MNT/symlinkname" ]; then
    fail "post-unlink-symlink: symlink still visible after rm"
else
    pass "post-unlink-symlink: symlink no longer visible"
fi
# the target file itself must be untouched -- only the symlink was removed
GOT="$(cat "$MNT/linkname")"
[ "$GOT" = "updated via linkname" ] && pass "post-unlink-symlink: target file content untouched" ||
    fail "post-unlink-symlink: target file content is '$GOT' after removing the symlink"

log "testing extended attributes (user.* xattrs)"
# No setfattr/getfattr in this image -- python3's os.*xattr wraps the same
# syscalls and is already present.
pyset() { python3 -c "import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())" "$@"; }
pyget() { python3 -c "import os,sys; sys.stdout.write(os.getxattr(sys.argv[1], sys.argv[2]).decode())" "$@"; }
pylist() { python3 -c "import os,sys; print(' '.join(sorted(os.listxattr(sys.argv[1]))))" "$@"; }
pydel() { python3 -c "import os,sys; os.removexattr(sys.argv[1], sys.argv[2])" "$@"; }

echo "xattr target" >"$MNT/xattrfile"
mkdir "$MNT/xattrdir"

pyset "$MNT/xattrfile" user.greeting "hello cetrafs"
GOT="$(pyget "$MNT/xattrfile" user.greeting)"
[ "$GOT" = "hello cetrafs" ] && pass "post-setxattr: getxattr returns what was set" ||
    fail "post-setxattr: getxattr returned '$GOT'"

LIST="$(pylist "$MNT/xattrfile")"
[ "$LIST" = "user.greeting" ] && pass "post-setxattr: listxattr shows exactly the one attribute" ||
    fail "post-setxattr: listxattr returned '$LIST'"

pyset "$MNT/xattrdir" user.note "a directory can have xattrs too"
GOT="$(pyget "$MNT/xattrdir" user.note)"
[ "$GOT" = "a directory can have xattrs too" ] && pass "post-setxattr: xattr on a directory works" ||
    fail "post-setxattr: directory getxattr returned '$GOT'"

if pyget "$MNT/xattrfile" user.nonexistent >/dev/null 2>&1; then
    fail "post-getxattr: getxattr of a nonexistent attribute unexpectedly succeeded"
else
    pass "post-getxattr: getxattr of a nonexistent attribute correctly fails (ENODATA)"
fi

BIGVAL="$(python3 -c "print('x' * 300)")"
if pyset "$MNT/xattrfile" user.toobig "$BIGVAL" 2>/dev/null; then
    fail "post-setxattr: an oversized (300-byte) xattr value unexpectedly succeeded"
else
    pass "post-setxattr: an oversized xattr value correctly rejected"
fi

log "remounting to verify xattrs persisted"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

GOT="$(pyget "$MNT/xattrfile" user.greeting)"
[ "$GOT" = "hello cetrafs" ] && pass "post-xattr-remount: file xattr persisted" ||
    fail "post-xattr-remount: file xattr is '$GOT'"
GOT="$(pyget "$MNT/xattrdir" user.note)"
[ "$GOT" = "a directory can have xattrs too" ] && pass "post-xattr-remount: directory xattr persisted" ||
    fail "post-xattr-remount: directory xattr is '$GOT'"

log "removing an xattr (exercises freeing the xattr block once it's emptied)"
pydel "$MNT/xattrfile" user.greeting
if pylist "$MNT/xattrfile" | grep -q user.greeting; then
    fail "post-removexattr: attribute still listed after removal"
else
    pass "post-removexattr: attribute no longer listed after removal"
fi
if pyget "$MNT/xattrfile" user.greeting >/dev/null 2>&1; then
    fail "post-removexattr: getxattr unexpectedly still succeeds after removal"
else
    pass "post-removexattr: getxattr correctly fails after removal (ENODATA)"
fi

log "remounting to verify the removal persisted (and the freed xattr block didn't leak)"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1
if pyget "$MNT/xattrfile" user.greeting >/dev/null 2>&1; then
    fail "post-removexattr-remount: removed attribute reappeared after remount"
else
    pass "post-removexattr-remount: removed attribute still gone after remount"
fi
GOT="$(pyget "$MNT/xattrdir" user.note)"
[ "$GOT" = "a directory can have xattrs too" ] && pass "post-removexattr-remount: unrelated directory xattr untouched" ||
    fail "post-removexattr-remount: directory xattr is '$GOT'"

log "checking statfs reports real, live free-space/free-inode counts"
read -r SF_BLOCKS SF_BFREE SF_FILES SF_FFREE <<<"$(stat -f -c '%b %f %c %d' "$MNT")"
# BG size (131072, from the mkfs output above) minus the BG's own header +
# data-bitmap overhead blocks -- statfs reports the usable data region, not
# the BG's raw on-disk footprint.
if [ "$SF_BLOCKS" -gt 0 ] && [ "$SF_BLOCKS" -le 131072 ]; then
    pass "statfs: total blocks ($SF_BLOCKS) is a sane usable-data count within the 131072-block BG"
else
    fail "statfs: total blocks is $SF_BLOCKS, expected 0 < x <= 131072"
fi
[ "$SF_FILES" = "1024" ] && pass "statfs: total inodes matches mkfs's -N 1024" ||
    fail "statfs: total inodes is $SF_FILES, expected 1024"
if [ "$SF_BFREE" -gt 0 ] && [ "$SF_BFREE" -lt "$SF_BLOCKS" ]; then
    pass "statfs: free blocks ($SF_BFREE) is nonzero and less than total"
else
    fail "statfs: free blocks is $SF_BFREE, expected 0 < x < $SF_BLOCKS"
fi
if [ "$SF_FFREE" -gt 0 ] && [ "$SF_FFREE" -lt "$SF_FILES" ]; then
    pass "statfs: free inodes ($SF_FFREE) is nonzero and less than total"
else
    fail "statfs: free inodes is $SF_FFREE, expected 0 < x < $SF_FILES"
fi

dd if=/dev/urandom of="$MNT/statfs-probe" bs=4096 count=3 status=none
NEW_BFREE="$(stat -f -c '%f' "$MNT")"
NEW_FFREE="$(stat -f -c '%d' "$MNT")"
[ "$NEW_BFREE" = "$((SF_BFREE - 3))" ] && pass "statfs: free blocks dropped by exactly 3 after a 3-block write" ||
    fail "statfs: free blocks is $NEW_BFREE, expected $((SF_BFREE - 3))"
[ "$NEW_FFREE" = "$((SF_FFREE - 1))" ] && pass "statfs: free inodes dropped by exactly 1 after creating a file" ||
    fail "statfs: free inodes is $NEW_FFREE, expected $((SF_FFREE - 1))"

rm "$MNT/statfs-probe"
RESTORED_BFREE="$(stat -f -c '%f' "$MNT")"
RESTORED_FFREE="$(stat -f -c '%d' "$MNT")"
[ "$RESTORED_BFREE" = "$SF_BFREE" ] && pass "statfs: free blocks restored after unlinking the probe file" ||
    fail "statfs: free blocks is $RESTORED_BFREE, expected back to $SF_BFREE"
[ "$RESTORED_FFREE" = "$SF_FFREE" ] && pass "statfs: free inodes restored after unlinking the probe file" ||
    fail "statfs: free inodes is $RESTORED_FFREE, expected back to $SF_FFREE"


ct_exit
