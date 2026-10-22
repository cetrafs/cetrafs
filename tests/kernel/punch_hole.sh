#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate(PUNCH_HOLE) frees exactly the right blocks
#
# Also the regression for the BG-descriptor checksum-length bug a partial
# punch surfaced: every earlier test that freed blocks netted back to
# zero, which happens to match an untouched counter by coincidence.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking fallocate(FALLOC_FL_PUNCH_HOLE) and the BG-descriptor checksum-length bug it caught"
# Independent throwaway image, same pattern as the REUSE_*/LOCK_* blocks
# above.
#
# This also happens to be the regression test for a real, previously
# undetected on-disk-format bug this feature's own testing caught:
# cetrafs_block_group_t/cetrafs_bg_header_t/cetrafs_zone_group_t were
# each documented as "exactly CETRAFS_BLOCK_SIZE", but their trailing
# pad[] arrays were sized against the wrong preceding-field byte count
# (off by 4, 16, and 4 bytes respectively), so sizeof() for all three
# fell short of a real block. kmod/alloc.c's
# cetrafs_bg_adjust_free_blocks() -- called on every single data-block
# alloc/free -- hashes the literal CETRAFS_BLOCK_SIZE when restamping a
# BG descriptor's checksum, while userspace/mkfs.c and userspace/fsck.c
# both hash sizeof(cetrafs_block_group_t) -- a silent 4-byte length
# mismatch that produced a 100%-reproducible BG0 descriptor CRC mismatch
# the moment anything exercised enough real kernel-side frees (punching
# an entire file's worth of blocks in one fallocate call, 256 separate
# cetrafs_free_data_block() calls here) ahead of an fsck run. No prior
# test in this suite ever ran fsck.cetra *after* a real mount's alloc/
# free activity (every existing fsck.cetra call here runs right after
# mkfs, before any mount) -- so this had never been caught before, even
# though it affects every ordinary write+unlink too, not just
# fallocate. Fixed by correcting the pad[] sizes so sizeof() for all
# three genuinely equals CETRAFS_BLOCK_SIZE (CETRAFS_VERSION bumped
# 0x0004->0x0005 since this changes on-disk struct layout).
FALLOC_IMG="$(mktemp /tmp/cetrafs-falloc-XXXXXX.img)"
truncate -s 560M "$FALLOC_IMG"
FALLOC_LOOPDEV="$(losetup --find --show "$FALLOC_IMG")"
FALLOC_MNT="$(mktemp -d /tmp/cetrafs-falloc-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$FALLOC_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$FALLOC_LOOPDEV" "$FALLOC_MNT"

dd if=/dev/zero bs=4096 count=256 2>/dev/null | tr '\0' 'A' > "$FALLOC_MNT/punchme"
sync

# Punch a hole in the *middle* of the file: the hole reads back as
# zero, bytes outside the hole are untouched, and the file's apparent
# size (FALLOC_FL_KEEP_SIZE) doesn't change.
fallocate --punch-hole --keep-size --offset 4096 --length 4096 "$FALLOC_MNT/punchme"

SIZE_AFTER="$(stat -c '%s' "$FALLOC_MNT/punchme")"
[ "$SIZE_AFTER" = "1048576" ] && pass "fallocate: file size unchanged after FALLOC_FL_KEEP_SIZE punch" ||
    fail "fallocate: file size is $SIZE_AFTER, expected 1048576 (FALLOC_FL_KEEP_SIZE)"

HOLE_BYTE="$(dd if="$FALLOC_MNT/punchme" bs=1 skip=4096 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
[ "$HOLE_BYTE" = "0" ] && pass "fallocate: punched range reads back as zero" ||
    fail "fallocate: punched range's first byte is '$HOLE_BYTE', expected 0"

BEFORE_HOLE_BYTE_COUNT="$(dd if="$FALLOC_MNT/punchme" bs=1 skip=0 count=4096 2>/dev/null | od -An -tu1 | tr -s ' ' '\n' | grep -c '^0$' || true)"
[ "$BEFORE_HOLE_BYTE_COUNT" = "0" ] && pass "fallocate: untouched bytes before the hole are unaffected" ||
    fail "fallocate: $BEFORE_HOLE_BYTE_COUNT unexpected zero byte(s) found before the punched range"

# An INTERIOR punch that SPLITS an extent (data on both sides of the
# hole) is the case that leaks: the free pass re-runs the punch over a
# copy of the old extent array purely to free the blocks, and a split
# needs one more entry than the array held. Sized with no slack, the
# free pass's own dry run saw count+1 > max and refused with -ENOSPC,
# freeing NOTHING -- the punched blocks stayed marked-in-use in the data
# bitmap with no extent referencing them (a silent space leak). A
# full-file punch never splits, so it masked this; and because a leak is
# an fsck WARN (exit 0), the exit-code check below never saw it either.
# This asserts free space is actually RECLAIMED and fsck reports no leak.
dd if=/dev/zero bs=4096 count=64 2>/dev/null | tr '\0' 'B' > "$FALLOC_MNT/splitme"
sync
FREE_BEFORE_PUNCH="$(stat -f -c '%f' "$FALLOC_MNT")"
fallocate --punch-hole --keep-size --offset "$((16 * 4096))" --length "$((8 * 4096))" "$FALLOC_MNT/splitme"
sync
FREE_AFTER_PUNCH="$(stat -f -c '%f' "$FALLOC_MNT")"
[ "$FREE_AFTER_PUNCH" -ge "$((FREE_BEFORE_PUNCH + 8))" ] &&
    pass "fallocate: an interior (splitting) punch reclaimed its 8 blocks ($FREE_BEFORE_PUNCH -> $FREE_AFTER_PUNCH)" ||
    fail "fallocate: interior punch reclaimed $((FREE_AFTER_PUNCH - FREE_BEFORE_PUNCH)) of 8 blocks ($FREE_BEFORE_PUNCH -> $FREE_AFTER_PUNCH) -- leaked"

# Now punch the *entire* file (the exact scenario that caught the
# checksum-length bug above: every block this file owns gets freed in
# one fallocate call).
fallocate --punch-hole --keep-size --offset 0 --length 1048576 "$FALLOC_MNT/punchme"

umount "$FALLOC_MNT"

# A leak is a WARN (fsck still exits 0), so check the OUTPUT, not just the
# exit code -- this is the assertion that discriminates the punch leak.
"$ROOT/userspace/fsck.cetra" "$FALLOC_LOOPDEV" >/tmp/cetrafs-falloc-fsck.out 2>&1
FSCK_RC=$?
if [ "$FSCK_RC" = 0 ] && ! grep -q "leaked" /tmp/cetrafs-falloc-fsck.out; then
    pass "fallocate: fsck.cetra is clean (no leak, no error) after the punch-hole run"
else
    fail "fallocate: fsck.cetra not clean after punch-hole (rc=$FSCK_RC): $(grep -iE 'leaked|err|warn' /tmp/cetrafs-falloc-fsck.out | head -3)"
fi

rm -f /tmp/cetrafs-falloc-fsck.out
rmdir "$FALLOC_MNT"
losetup -d "$FALLOC_LOOPDEV"
rm -f "$FALLOC_IMG"


ct_exit
