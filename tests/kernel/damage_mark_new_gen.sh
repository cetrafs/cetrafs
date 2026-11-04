#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# damage found in a reused inode number is marked against the new file
#
# Damage found in an inode marks it -- per incarnation, by generation --
# and every later write, unlink and truncate of that incarnation is
# refused (EUCLEAN), so nothing is freed on the strength of a damaged
# tree. The mark was stored only when the number had none: a peer that
# deleted the file and reused the number (which this node never
# allocates, so nothing erased the old mark) left the old generation
# there, damage in the NEW file stored nothing, and the new file's
# generation did not match -- unlink went through on a file just found
# damaged.
#
# Staged: a file whose extent names the inode table is read (damage,
# generation g1), the record is then rewritten as a peer's reuse of the
# number under a new generation with the same bad extent, and read
# again. Writes and unlink of the new file must be refused.
#
# DISCRIMINATION: with the mark stored only when empty, the write past
# the damage and the unlink both go through.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PPOKE="$(ct_helper extent_phys_poke)"
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dmgen)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dmgen)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/victim" bs=4096 count=4 status=none
sync
VINO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"
"$PPOKE" "$IMG" "$VINO" inode_table >/dev/null || { fail "setup: extent_phys_poke failed"; ct_exit; }
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
errno_of() { { "$@" 2>&1 >/dev/null || true; } | grep -o "Structure needs cleaning\|Input/output error" | head -1 || true; }

MARK="$(dmesg_mark)"
cat "$MNT/victim" >/dev/null 2>&1 && { fail "setup: the damaged extent was read without complaint"; ct_exit; }
dmesg_since "$MARK" | grep -q "ino=$VINO is damaged" ||
    { fail "setup: the first incarnation was not marked"; ct_exit; }
pass "setup: damage in ino $VINO's first incarnation marked"

# A peer deletes the file and creates another that gets the number: a
# new generation, and (as damage goes) the same bad extent.
"$IPOKE" "$IMG" reuse "$VINO" 0x5eed0001 1 >/dev/null 2>&1
stat "$MNT/victim" >/dev/null 2>&1 || true
cat "$MNT/victim" >/dev/null 2>&1 && { fail "setup: the new incarnation's bad extent was read without complaint"; ct_exit; }
pass "setup: the new incarnation's damage was found"

E="$(errno_of dd if=/dev/zero of="$MNT/victim" bs=4096 seek=100 count=1 conv=notrunc status=none)"
[ "$E" = "Structure needs cleaning" ] && pass "a write to the new, damaged file is refused (EUCLEAN)" ||
    fail "a write to the new, damaged file got '${E:-success}' -- the old incarnation's mark hid it"
E="$(errno_of rm -f "$MNT/victim")"
[ "$E" = "Structure needs cleaning" ] && [ -e "$MNT/victim" ] &&
    pass "and so is unlinking it -- nothing freed on a damaged tree" ||
    fail "unlink of the new, damaged file got '${E:-success}'"
ct_umount "$MNT"
ct_exit
