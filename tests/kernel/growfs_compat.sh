#!/usr/bin/env bash
# a volume formatted by the PREVIOUS release grows under this build, and a real device resize behaves like an undersized mkfs
#
# Two claims this suite exists to stop being assumptions.
#
# 1. NO REFORMAT. The grow design deliberately avoids bumping
#    CETRAFS_VERSION -- new superblock fields come out of the
#    zero-filled reserved area, sizeof(superblock) and the checksum
#    offset do not move -- so a volume formatted by an earlier build is
#    supposed to grow in place. Everything else in this tree tests grows
#    of volumes this build formatted itself, which cannot catch a
#    divergence between the two. So the old mkfs.cetra is rebuilt from
#    git HEAD and used to make the volume.
#
# 2. THE UNDERSIZE SHORTCUT IS SOUND. Every other grow suite formats
#    part of a device with `mkfs.cetra -s` and grows into the rest,
#    because resizing a LUN is not something a test can do. This one
#    does the real thing instead -- truncate(1) the backing file and
#    losetup -c so the BLOCK DEVICE genuinely changes size under the
#    filesystem -- and requires the same outcome. Without this, "an
#    undersized mkfs presents the grow with the same delta as a real
#    resize" is a load-bearing claim nobody has checked.
#
# The old mkfs has no -s flag, which is also how this suite proves it
# really is the old binary and not the new one under another name.
#
# NOT claimed, and deliberately not tested, because it is false: a
# GROWN volume is not readable by the previous release. That build's
# fsck requires pending_free_start to sit immediately after the node
# table, and its kernel module requires bg_regions_start >= 1+Z+B --
# both of which a relocated, grown layout violates. Growing is a
# one-way door with respect to older binaries. See
# docs/internal/EXTENDFS-DESIGN.md.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

OLD="$(ct_mnt growoldtools)"
MNT="$(ct_mnt growcompat)"
WORK="$(ct_mnt growcompatwork)"
POKE="$(ct_helper sb_poke)"
DUMP="$(ct_tmp growcompatdump)"

sbver() { "$POKE" "$1" > "$DUMP" 2>/dev/null || true; sed -n 's/^version=//p' "$DUMP" | head -1; }

# The PREVIOUS RELEASE means the newest tag that is NOT the version this
# tree is, which is the version debian/changelog names (the single source
# of it -- see docs/internal/RELEASE.md).
#
# `git describe --abbrev=0` was wrong in both directions. Before a
# release it names the last tag, which is right by accident; the moment
# that release is TAGGED it names the tree's own version, and the suite
# starts comparing this build against itself. That is exactly what
# happened when 0.9 was tagged: the "old" mkfs was the current one, and
# the -s check below -- there to prove the old binary really is old --
# caught it and failed rather than letting the suite pass vacuously.
CURVER="$(sed -n '1s/^cetrafs (\([^)]*\)).*/\1/p' "$ROOT/debian/changelog")"
# Release tags only: publish-tag.sh keeps the published ones under
# public/<version>, which sort first and are the same code anyway.
PREV="$(git -C "$ROOT" tag --sort=-v:refname 2>/dev/null | grep -v / | grep -vx "$CURVER" | head -1 || true)"
[ -n "$PREV" ] || { skip "no earlier release tag to compare against (this tree is $CURVER)"; ct_exit; }
log "rebuilding mkfs.cetra from $PREV (the previous release)"
mkdir -p "$OLD/src"
ok=1
for f in include/cetrafs.h userspace/mkfs.c userspace/fsck.c userspace/crc32c.h userspace/devutil.h; do
    git -C "$ROOT" show "$PREV:$f" > "$OLD/src/$(basename "$f")" 2>/dev/null || ok=0
done
if [ "$ok" != "1" ]; then
    skip "cannot read $PREV from git -- no previous-release sources to build"
    ct_exit
fi
if ! (cd "$OLD/src" && cc -D_FILE_OFFSET_BITS=64 -I . -O2 -std=gnu99 -w -o "$OLD/mkfs.old" mkfs.c) 2>"$WORK/build.log"; then
    fail "could not build the previous release's mkfs: $(tail -3 "$WORK/build.log" | tr '\n' ' ')"
    ct_exit
fi
pass "built the previous release's mkfs.cetra"

# If this binary understands -s it is not the old one, and the whole
# suite would be testing this build against itself.
#
# Asked of the USAGE TEXT, not by running it against a device. The
# earlier version ran `mkfs.old /dev/null -s 100M` and checked for the
# undersize line -- which never appears, because mkfs rejects /dev/null
# long before it gets that far. It passed whether or not the binary
# understood -s, i.e. it could not fail.
# Captured, THEN matched. `mkfs.old 2>&1 | grep -q` returns mkfs's exit
# status under `set -o pipefail`, and mkfs with no arguments exits 2 for
# usage -- so the pipeline was non-zero whether or not grep matched, and
# BOTH branches reached a pass. This guard could not fail, which is the
# second time it has been wrong: the first version ran mkfs against
# /dev/null, where it dies before printing the usage text at all.
old_usage="$("$OLD/mkfs.old" 2>&1 || true)"
if grep -qE '^  -s:|\[-s ' <<<"$old_usage"; then
    fail "the 'old' mkfs understands -s -- it is not the previous release, this suite proves nothing"
    ct_exit
fi
pass "the old mkfs has no -s flag, so it really is the previous release"

# A 600 MiB backing file, grown later with truncate+losetup -c.
IMG="$(ct_big_image 600 growcompat)"
DEV="$(ct_loop "$IMG")"

log "formatting the WHOLE 600 MiB device with the previous release's mkfs"
if "$OLD/mkfs.old" "$DEV" -b 512 -z 1 -J 0 -N 2048 -f >"$WORK/mkfs.log" 2>&1; then
    pass "the previous release formatted the volume"
else
    fail "old mkfs failed: $(tail -3 "$WORK/mkfs.log" | tr '\n' ' ')"
    ct_exit
fi

# The previous release stamps the OLD format version. Accepting it is
# the whole of the no-reformat promise, so it is asserted rather than
# assumed -- and if this ever reads 9, the "old" mkfs is not old.
v="$(sbver "$DEV")"
[ "$v" = "8" ] && pass "the previous release's volume carries format version 8" ||
    fail "expected format version 8 from the old mkfs, got '$v'"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "this build's fsck accepts the previous release's volume" ||
    fail "this build's fsck rejects a volume the previous release just formatted"

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir -p "$MNT/dir/sub"
i=0
while dd if=/dev/urandom of="$MNT/dir/sub/old_$i" bs=1M count=8 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 200 ] && break
done
sync
[ "$i" -gt 4 ] && pass "wrote $i files to the previous release's volume" ||
    fail "could not write to the old volume"
# Measured from the DEVICE, not the page cache. Filling to ENOSPC with
# delayed allocation can leave a file short on disk while the cache
# still holds the bytes the write put there, so a digest taken while
# mounted records the cache and disagrees with every later read. That
# produced intermittent "the grow corrupted my data" failures on a
# different file each time, in a suite where the grow had not touched
# the data at all. Unmount first; then every digest is a disk read.
size_before="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
( cd "$MNT" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$(md5sum < "$f" | cut -d' ' -f1)" "$f"; done > "$WORK/dig" )
ct_umount "$MNT"

# ---------------------------------------------------------- real resize
log "growing the BLOCK DEVICE itself: truncate + losetup -c"
truncate -s 1400M "$IMG"
if losetup -c "$DEV" 2>/dev/null; then
    pass "the loop device picked up the new size"
else
    fail "losetup -c failed -- cannot test a real device resize"
    ct_exit
fi
newsz="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
[ "$newsz" -gt 629145600 ] && pass "the device now reports $newsz bytes" ||
    fail "the device still reports $newsz bytes after losetup -c"

log "growing the filesystem into space that genuinely appeared"
if out="$(ct_growfs "$DEV" 2>&1)"; then
    pass "growfs grew a previous-release volume after a real device resize"
else
    fail "growfs failed on a previous-release volume: $out"
fi
ct_fsck "$DEV" >/dev/null 2>&1 && pass "the grown volume is clean" || fail "the grown volume is not clean"

# Growing stamps the current version, which is what stops the previous
# release from touching the volume again -- and makes it say so plainly
# instead of reporting a healthy layout as damage.
v="$(sbver "$DEV")"
[ "$v" = "9" ] && pass "the grow bumped the format version 8 -> 9 (one-way door)" ||
    fail "the grow left the format version at '$v'; the previous release would still try to read it"

ct_mount "$DEV" "$MNT"
size_after="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
[ "$size_after" -gt "$size_before" ] && pass "capacity grew ($size_before -> $size_after bytes)" ||
    fail "capacity did not grow: $size_before -> $size_after"

( cd "$MNT" && md5sum -c --quiet "$WORK/dig" ) &&
    pass "every file written by the previous release still verifies" ||
    fail "data written by the previous release did not survive the grow"

w=0
while dd if=/dev/urandom of="$MNT/new_$w" bs=1M count=8 status=none 2>/dev/null; do
    w=$((w + 1))
    [ "$w" -gt 200 ] && break
done
sync
[ "$w" -gt 4 ] && pass "wrote $w files into the newly appeared space" ||
    fail "the newly appeared space took only $w files"
( cd "$MNT" && md5sum -c --quiet "$WORK/dig" ) &&
    pass "the previous release's data still verifies after the new space was used" ||
    fail "using the new space corrupted the previous release's data"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean at the end" || fail "not clean at the end"

ct_exit
