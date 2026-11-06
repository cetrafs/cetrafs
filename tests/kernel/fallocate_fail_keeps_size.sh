#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a fallocate that fails publishes no size past what it allocated
#
# The early exit of cetrafs_do_allocate() needed keep_size or a range
# inside i_size, so a plain fallocate(fd, 0, 0, N) that hit ENOSPC, EIO or
# a fatal signal before its first block fell through, published size = N
# and returned the error (audit 2026-11-06 M14). A stop part-way grew the
# size to N as well, over blocks it never allocated.
#
# Staged with a real ENOSPC: the volume filled by one file, then
#  (1) a fallocate of a new file with nothing free: must fail, size 0;
#  (2) a 1 MiB file deleted, a 64 MiB fallocate: must fail part-way, and
#      the size must not exceed the space that was free.
# Both checked again after a remount (the published record, not i_size).
#
# DISCRIMINATION: with the old early exit, (1) leaves the file at 64 MiB;
# with the size grown to the range end, (2) does too.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fallocate >/dev/null || { skip "fallocate is not installed"; ct_exit; }

DEV="$(ct_dev 560 fallocfail)"
MNT="$(ct_mnt fallocfail)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0

dd if=/dev/zero of="$MNT/hole" bs=1M count=1 conv=fsync status=none
dd if=/dev/zero of="$MNT/fill" bs=1M conv=fsync status=none 2>/dev/null || true
sync
touch "$MNT/empty"
if fallocate -l 1M "$MNT/probe" 2>/dev/null; then
    fail "setup: the volume is not full (a 1 MiB fallocate succeeded)"; ct_umount "$MNT"; ct_exit
fi
rm -f "$MNT/probe"

RC=0; fallocate -l 64M "$MNT/empty" 2>/dev/null || RC=$?
[ "$RC" != 0 ] || { fail "setup: a fallocate on a full volume succeeded"; ct_umount "$MNT"; ct_exit; }
S1="$(stat -c %s "$MNT/empty")"
[ "$S1" = 0 ] && pass "a fallocate that allocated nothing left the size at 0" ||
    fail "a failed fallocate that allocated nothing published size $S1"

rm -f "$MNT/hole"
sync
touch "$MNT/part"
RC=0; fallocate -l 64M "$MNT/part" 2>/dev/null || RC=$?
[ "$RC" != 0 ] || { fail "setup: a 64 MiB fallocate into ~1 MiB of free space succeeded"; ct_umount "$MNT"; ct_exit; }
S2="$(stat -c %s "$MNT/part")"
B2="$(($(stat -c %b "$MNT/part") * 512))"
[ "$B2" -gt 0 ] || { fail "setup: the part-way fallocate allocated nothing"; ct_umount "$MNT"; ct_exit; }
[ "$S2" -le "$B2" ] && [ "$S2" -gt 0 ] && pass "a part-way fallocate grew the size only over what it allocated ($S2 <= $B2)" ||
    fail "a part-way fallocate published size $S2 over $B2 bytes allocated"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c %s "$MNT/empty")" = "$S1" ] && [ "$(stat -c %s "$MNT/part")" = "$S2" ] &&
    pass "the published records agree after a remount" ||
    fail "after a remount: empty $(stat -c %s "$MNT/empty") (was $S1), part $(stat -c %s "$MNT/part") (was $S2)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -i err <<<"$OUT" | head -2)"
ct_exit
