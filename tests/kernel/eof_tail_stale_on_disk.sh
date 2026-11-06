#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growing a file zeroes its old EOF block's tail even when that tail is only on disk
#
# Truncate publishes the smaller size and then zeroes the tail of the
# block at the new end in the page cache. A crash between the two leaves
# the file's own old bytes past EOF on the device (audit 2026-11-06
# L22). They stay unreadable while the size covers them -- until the
# file grows. The growing paths zeroed the old EOF folio's tail only if
# it was CACHED, on the premise that writeback had zeroed it otherwise;
# after the crash that premise is false, and a truncate up or a write
# past EOF made the stale bytes part of the file again.
#
# Staged as that crash leaves it: a file of 8192 bytes of 'A' whose
# record is set to 5000 bytes on the unmounted image. After a fresh
# mount (nothing cached) the file is grown by truncate, and a second
# one by a write past EOF; bytes 5000..8191 must read as zeros.
#
# DISCRIMINATION: zeroing only a cached folio, both read back 'A'.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 eoftail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt eoftail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for f in t w; do
    python3 -c 'import sys; open(sys.argv[1], "wb").write(b"A" * 8192)' "$MNT/$f"
done
sync
TI="$(stat -c %i "$MNT/t")"
WI="$(stat -c %i "$MNT/w")"
ct_umount "$MNT"
"$IPOKE" "$IMG" setsize "$TI" 5000 2>/dev/null
"$IPOKE" "$IMG" setsize "$WI" 5000 2>/dev/null
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(stat -c %s "$MNT/t")" = 5000 ] && [ "$(stat -c %s "$MNT/w")" = 5000 ] ||
    { fail "setup: the poked sizes did not take ($(stat -c %s "$MNT/t"), $(stat -c %s "$MNT/w"))"; ct_umount "$MNT"; ct_exit; }
pass "setup: both files are 5000 bytes with their old bytes still on disk past EOF"

truncate -s 8192 "$MNT/t"
python3 -c 'import os,sys; f=os.open(sys.argv[1], os.O_WRONLY); os.pwrite(f, b"B", 12288); os.close(f)' "$MNT/w"
# What the range holds: a count of non-zero bytes in [5000, 8192).
nz() { python3 -c 'import sys; d=open(sys.argv[1],"rb").read()[5000:8192]; print(len(d) - d.count(0))' "$1"; }
N="$(nz "$MNT/t")"
[ "$N" = 0 ] && pass "truncate up: the grown range reads as zeros" ||
    fail "truncate up: $N stale byte(s) of the file's old tail came back"
N="$(nz "$MNT/w")"
[ "$N" = 0 ] && pass "write past EOF: the gap reads as zeros" ||
    fail "write past EOF: $N stale byte(s) of the file's old tail came back"
# And after a remount: what reached the device.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
N="$(nz "$MNT/t")$(nz "$MNT/w")"
[ "$N" = 00 ] && pass "and the zeros are what reached the device" || fail "after a remount the gaps hold stale bytes ($N)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
