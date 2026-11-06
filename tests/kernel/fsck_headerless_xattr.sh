#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck still counts the xattr block of a record with no extent header
#
# A live record with no extent header and no extent bytes is reported
# (the kernel refuses to map through it) but hides no blocks, so repair
# stays enabled. The pass then skipped the record before reaching its
# xattr block, which therefore read as leaked -- and a repair cleared a
# block the record still names (audit 2026-11-06 L23).
#
# Staged: an empty file with one xattr; its extent header's magic is
# zeroed on the image. fsck must report the header and must not count
# the xattr block as leaked.
#
# DISCRIMINATION: skipping the record, fsck reports one leaked block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fsckhx)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckhx)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/x"
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"v" * 64)' "$MNT/x"
sync
INO="$(stat -c %i "$MNT/x")"
ct_umount "$MNT"
XB="$("$IPOKE" "$IMG" xattrblk "$INO" 2>/dev/null | grep -o '[0-9]\+' | tail -1)"
[ -n "$XB" ] && [ "$XB" != 0 ] || { fail "setup: the file has no xattr block ($XB)"; ct_exit; }
OUT0="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "leaked" <<<"$OUT0" && { fail "setup: fsck reports leaks before the poke: $(grep leaked <<<"$OUT0")"; ct_exit; }
"$IPOKE" "$IMG" ehset "$INO" magic 0 2>/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $INO has no extent header" <<<"$OUT" ||
    { fail "setup: fsck did not report the missing header: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"; ct_exit; }
pass "setup: fsck reports inode $INO's missing extent header"
grep -q "leaked" <<<"$OUT" && fail "fsck counts the xattr block $XB as leaked: $(grep leaked <<<"$OUT" | head -1)" ||
    pass "and still counts its xattr block $XB as referenced"
ct_exit
