#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r never restamps a never-written inode record into a valid one
#
# A create that stopped between taking the number and writing the record
# leaves an all-zero slot marked in use. If a dirent names it, the link
# count pass under -r "repaired" its nlink: read the slot, set the field,
# restamp both checksums -- over zeroes. That minted a checksum-valid
# record for inode 0, mode 0, and the next run reported "slot holds a
# valid record for inode 0" and blocked every repair on the volume
# (audit 2026-11-06 M12). Field repairs now patch only a valid record of
# that number.
#
# Staged: a file, then its record zeroed on the device. fsck -r, then
# fsck: the slot must still be all zeroes, and the second run must not
# report a valid record for another inode.
#
# DISCRIMINATION: with the restamp unguarded, the slot holds a valid
# record for inode 0 after -r.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 zerorec)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zerorec)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo data >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
ITS="$("$SBPOKE" "$IMG" | sed -n 's/.*inode_table_start[=: ]*\([0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$ITS" ] || { fail "setup: no inode_table_start in the superblock dump"; ct_exit; }
SLOT=$((ITS + INO - 1))
dd if=/dev/zero of="$IMG" bs=4096 seek="$SLOT" count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV" 2>/dev/null || true
zero() { [ "$(dd if="$IMG" bs=4096 skip="$SLOT" count=1 status=none | tr -d '\0' | wc -c)" = 0 ]; }
zero || { fail "setup: the slot is not all zero"; ct_exit; }
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
grep -q "inode $INO is marked in use but its record was never written" <<<"$OUT" ||
    { fail "setup: fsck does not see the never-written record: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)"; ct_exit; }

"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true
blockdev --flushbufs "$DEV" 2>/dev/null || true
zero && pass "fsck -r left the never-written record all zero" ||
    fail "fsck -r wrote into the never-written record"
OUT2="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
grep -q "slot holds a valid record for inode" <<<"$OUT2" &&
    fail "the next run finds a minted record: $(grep -m1 'slot holds a valid record' <<<"$OUT2")" ||
    pass "the next run finds no record minted into the slot"
grep -qi "repair is blocked\|repair blocked\|will not repair" <<<"$OUT2" &&
    log "note: the next run reports repair blocked: $(grep -mi1 'block' <<<"$OUT2")" || true
ct_exit
