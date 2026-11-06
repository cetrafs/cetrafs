#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r re-stamps the root directory's torn tail instead of erasing every top-level name
#
# A dirent block whose entry table is intact and whose tail checksum is
# not -- a crash mid-write of the tail sector -- is re-stamped by fsck -r,
# keeping every name. The root's first block skipped that check and was
# rebuilt to '.' and '..' at once, before the run knew whether repair was
# safe: every top-level name gone, and if a later pass blocked repair,
# nothing linked the orphans back (audit 2026-11-06 M11).
#
# Staged: six names in the root, the tail CRC of the root's block
# overwritten. fsck -r must re-stamp it with the entry table byte for
# byte, and the six names must still be there.
#
# DISCRIMINATION: with the root rebuilt unconditionally, the entry table
# changes and the names are gone from the root.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 roottail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt roottail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for n in alpha bravo charlie delta echo foxtrot; do echo "$n" >"$MNT/$n"; done
sync
NAMES_BEFORE="$(ls "$MNT" | sort | tr '\n' ' ')"
ct_umount "$MNT"
case "$NAMES_BEFORE" in *"alpha bravo charlie delta echo foxtrot"*) ;; *)
    fail "setup: the root does not hold the six names: '$NAMES_BEFORE'"; ct_exit ;; esac
ct_fsck "$DEV" >/dev/null || { fail "setup: the volume is already reported corrupt"; ct_exit; }

PHYS="$("$IPOKE" "$IMG" extents 1 | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
[ -n "$PHYS" ] && [ "$PHYS" != 0 ] || { fail "setup: could not locate the root's dirent block"; ct_exit; }
BEFORE="$(dd if="$IMG" bs=4096 skip="$PHYS" count=1 2>/dev/null | head -c 4088 | md5sum)"
printf '\xde\xad\xbe\xef' | dd of="$IMG" bs=1 seek=$((PHYS * 4096 + 4096 - 4)) count=4 conv=notrunc status=none
blockdev --flushbufs "$DEV" 2>/dev/null || true

OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
grep -q "root dirent block tail checksum invalid" <<<"$OUT" ||
    { fail "setup: fsck did not report the root's broken tail: $(grep '^ERR' <<<"$OUT" | head -2)"; ct_exit; }

REP="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "re-stamped the root directory's dirent tail" <<<"$REP" &&
    pass "fsck -r re-stamped the root's tail" ||
    fail "fsck -r did not re-stamp the root's tail: $(grep -E 'rebuilt|re-stamped|^ERR' <<<"$REP" | head -2)"
blockdev --flushbufs "$DEV" 2>/dev/null || true
AFTER="$(dd if="$IMG" bs=4096 skip="$PHYS" count=1 2>/dev/null | head -c 4088 | md5sum)"
[ "$AFTER" = "$BEFORE" ] && pass "the root's entry table came through byte for byte" ||
    fail "the repair rewrote the root's entries"
ct_fsck "$DEV" >/dev/null && pass "the volume is clean after the repair" || fail "fsck still reports problems"
ct_mount "$DEV" "$MNT"
NAMES_AFTER="$(ls "$MNT" 2>/dev/null | sort | tr '\n' ' ')"
ct_umount "$MNT"
[ "$NAMES_AFTER" = "$NAMES_BEFORE" ] && pass "every top-level name survived" ||
    fail "top-level names lost: before '$NAMES_BEFORE', after '$NAMES_AFTER'"
ct_exit
