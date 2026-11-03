#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a valid inode record in the wrong slot is refused, not served as the inode asked for
#
# cetrafs_read_raw_inode() checked the record's checksums and never asked
# whether the record was the one requested. A record that is valid but
# sits in another inode's slot -- a misdirected write, or a record copied
# to where it does not belong -- was taken as that inode's: its mode, its
# size and its extents. Reading the file then returned the OTHER file's
# data, with nothing logged. fsck did not compare the two either.
#
# Played by copying file a's record block over file b's slot on the
# backing image. b must now fail to read (EUCLEAN, counted as damage),
# a must read as before, and fsck must name the slot.
#
# DISCRIMINATION: without the check, b reads back a's contents.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SBPOKE="$(ct_helper sb_poke)"
DEV="$(ct_dev 560 wrongslot)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt wrongslot)"
ct_mkfs_small "$DEV" >/dev/null
ITAB="$("$SBPOKE" "$DEV" | sed -n 's/^inode_table_start=//p')"
[ -n "$ITAB" ] || { fail "setup: no inode_table_start from sb_poke"; ct_exit; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

echo "file a" >"$MNT/a"
echo "file b" >"$MNT/b"
A="$(stat -c %i "$MNT/a")"
B="$(stat -c %i "$MNT/b")"
ct_umount "$MNT"
dd if="$BACK" of="$BACK" bs=4096 skip=$((ITAB + A - 1)) seek=$((ITAB + B - 1)) count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV"

ct_mount "$DEV" "$MNT"
MARK="$(dmesg_mark)"
GOT="$(cat "$MNT/b" 2>/dev/null || true)"
if [ "$GOT" = "file a" ]; then
    fail "b's slot holds a's record and reading b returned a's data"
elif [ -z "$GOT" ]; then
    pass "reading b fails instead of serving a's data"
else
    fail "reading b returned '$GOT'"
fi
dmesg_since "$MARK" | grep -q "ino=$B: its slot holds a valid record for ino=$A -- misplaced" &&
    pass "and the kernel says what it found" || fail "nothing logged about the misplaced record"
[ "$(sed -n 's/^corruptions: //p' "$PROC/info")" -ge 1 ] && pass "counted as damaged metadata" ||
    fail "corruptions: $(sed -n 's/^corruptions: //p' "$PROC/info")"
[ "$(cat "$MNT/a")" = "file a" ] && pass "a still reads as itself" || fail "a no longer reads"
ct_umount "$MNT"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "^ERR: inode $B's slot holds a valid record for inode $A" <<<"$OUT" &&
    pass "fsck names the slot" || fail "fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"
ct_exit
