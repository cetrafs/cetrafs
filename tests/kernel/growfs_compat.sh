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

# THE PREVIOUS RELEASE, for this suite, is not "the tag before this one".
# It is the newest release whose on-disk format equals this build's
# CETRAFS_VERSION_MIN -- the oldest format we still accept, which is the
# whole reason the compatibility window exists and the only thing worth
# growing in place.
#
# Two earlier spellings both rotted, in opposite directions:
#
#   `git describe --abbrev=0` named the tree's OWN version the moment
#   that version was tagged, so the suite compared this build against
#   itself (caught when 0.9 was tagged).
#
#   "newest tag that is not the changelog version" then named 0.9 once
#   0.9.1 existed -- a real previous release, but one that writes the
#   CURRENT format, so there was no old format left to test.
#
# Asking the tags what format they produce cannot rot: it is the same
# question the window is defined in terms of.
# Both are read from the header, and CETRAFS_VERSION_MIN may be the
# literal token CETRAFS_VERSION rather than a number -- which is exactly
# what "the window is closed" looks like in the source. Resolve that one
# level of indirection instead of parsing it as 0 and silently skipping.
hdrdef() { sed -n "s/^#define $1  *//p" "$2" | head -1 | awk '{print $1}'; }
CURFMT="$(hdrdef CETRAFS_VERSION "$ROOT/include/cetrafs.h")"
MINTOK="$(hdrdef CETRAFS_VERSION_MIN "$ROOT/include/cetrafs.h")"
[ "$MINTOK" = "CETRAFS_VERSION" ] && MINTOK="$CURFMT"
MINVER="$(awk -v v="$MINTOK" 'BEGIN{print strtonum(v)}')"
CURFMT="$(awk -v v="$CURFMT" 'BEGIN{print strtonum(v)}')"   # decimal, as the poke tool reports it
[ "${MINVER:-0}" -gt 0 ] || fail "could not resolve CETRAFS_VERSION_MIN (read '$MINTOK')"

# This tree's own version never counts as the previous release, however
# the formats line up -- with the window closed, MIN equals VERSION and
# the newest tag writing that format is this one.
CURVER="$(sed -n '1s/^cetrafs (\([^)]*\)).*/\1/p' "$ROOT/debian/changelog")"

PREV=""
for TAG in $(git -C "$ROOT" tag --sort=-v:refname 2>/dev/null | grep -v / | grep -vx "$CURVER"); do
    TAGVER="$(git -C "$ROOT" show "$TAG:include/cetrafs.h" 2>/dev/null |
        sed -n 's/^#define CETRAFS_VERSION  *//p' | head -1 | awk '{print strtonum($1)}')"
    [ -n "$TAGVER" ] || continue
    if [ "$TAGVER" = "$MINVER" ]; then
        PREV="$TAG"
        break
    fi
done
[ -n "$PREV" ] || { skip "no released tag writes format $MINVER, so there is no older format to grow"; ct_exit; }
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

# "Is this really the old binary?" is now answered by WHICH TAG WE
# PICKED -- the newest one whose CETRAFS_VERSION equals this build's
# CETRAFS_VERSION_MIN -- and proved empirically a few lines below, where
# the volume it formats must carry that format number.
#
# It used to be asked of the usage text instead: "if this binary
# understands -s it is not the old one". That proxy has now been wrong
# three times. Run against /dev/null it died before printing any usage
# at all; piped into grep under `set -o pipefail` it returned mkfs's
# exit status rather than grep's, so both branches passed; and finally
# it became simply false, because -s shipped in 0.9 and 0.9 is a
# legitimate previous release. A proxy for a property is worth exactly
# as long as nobody changes the property.
log "previous release: $PREV (writes on-disk format $MINVER, this build's CETRAFS_VERSION_MIN)"

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
[ "$v" = "$MINVER" ] && pass "the previous release's volume carries format version $MINVER" ||
    fail "expected format version $MINVER from $PREV's mkfs, got '$v'"

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
# With the compatibility window closed these are the same number, so
# the grow leaves it alone rather than bumping it -- the assertion is
# that the grown volume ends at the CURRENT format either way.
[ "$v" = "$CURFMT" ] && pass "the grown volume carries format version $CURFMT" ||
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
