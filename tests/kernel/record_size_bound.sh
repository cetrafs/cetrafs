#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record whose size the format cannot hold is damage, not a file
#
# A record's size is a length read off the device, and it became i_size
# unchecked: past 2^32 blocks (16 TiB) it names blocks no extent can
# address, and past 2^63 it is a NEGATIVE loff_t to every VFS path that
# reads it. The checksum is valid either way; it proves the bytes are
# what was written, not that they make sense.
#
# Staged offline with valid checksums: one file 4 KiB past the ceiling,
# one past 2^63. Both must be refused (EUCLEAN) and counted.
#
# DISCRIMINATION: without the bound both stat fine, with the bogus size.
# The control only stats: a negative i_size is not read on a test box.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 sizebound)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt sizebound)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo a >"$MNT/big"; echo b >"$MNT/neg"; echo c >"$MNT/fine"
sync
BI="$(stat -c %i "$MNT/big")"; NI="$(stat -c %i "$MNT/neg")"
ct_umount "$MNT"
"$IPOKE" "$IMG" setsize "$BI" $(((1 << 44) + 4096)) 2>/dev/null
"$IPOKE" "$IMG" setsize "$NI" 9223372036854779904 2>/dev/null
[ "$("$IPOKE" "$IMG" size "$NI")" = 9223372036854779904 ] || { fail "setup: the size was not planted"; ct_exit; }
blockdev --flushbufs "$DEV"

ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")/info"
for f in big neg; do
    if OUT="$(stat -c %s "$MNT/$f" 2>&1)"; then
        fail "$f: a size the format cannot hold was accepted (stat says $OUT)"
    elif grep -q "Structure needs cleaning" <<<"$OUT"; then
        pass "$f: refused as damage (EUCLEAN)"
        cat "$MNT/$f" >/dev/null 2>&1 && fail "$f: but its contents were read" || pass "$f: and its contents are not read"
    else
        fail "$f: refused, but not as damage: $OUT"
    fi
done
[ "$(sed -n 's/^corruptions: //p' "$PROC")" -ge 1 ] && pass "counted as corruption" ||
    fail "not counted as corruption"
[ "$(cat "$MNT/fine")" = c ] && pass "an undamaged file beside them reads normally" || fail "the undamaged file did not read"
ct_umount "$MNT"
ct_exit
