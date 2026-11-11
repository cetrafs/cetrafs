#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports a root whose leaf address is off the volume as damage, not as "could not examine"
#
# A root directory past its four inline extents (about 58 names) keeps
# an index inline, and fsck read the leaf it names with no bound on the
# address: one past the device was a short read, and fsck exited 3 --
# "could not examine" -- about a volume it had examined perfectly well
# and whose root is damaged (audit 2026-11-11 F5).
#
#  0. a root grown to five extents is at depth 1, and the volume is clean.
#  1. its index points past the device: ERR naming the leaf, exit 1.
#
# DISCRIMINATION (2026-11-11, fsck.c before this fix): 1 exits 3 with
# "unexpected end of device".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PHYS="$(ct_helper extent_phys_poke)"
REC="$(ct_helper inode_block_poke)"
SB_POKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 rootleaf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rootleaf)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# A data allocation between each growth, so the root's blocks cannot
# merge: five extents, depth 1 (as fsck_lostfound_spilled_root.sh).
for b in $(seq 0 6); do
    for i in $(seq 1 15); do : >"$MNT/r${b}_$i"; done
    dd if=/dev/zero of="$MNT/pad$b" bs=4096 count=1 status=none
    sync
done
ct_umount "$MNT"
grep -q "depth=1" <<<"$("$REC" "$IMG" extents 1 2>&1)" ||
    { fail "0 setup: the root did not spill: $("$REC" "$IMG" extents 1 2>&1)"; ct_exit; }
blockdev --flushbufs "$DEV"
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "0 setup: the volume is not clean"; ct_exit; }
TOT="$("$SB_POKE" "$IMG" | sed -n 's/^total_blocks=//p')"
pass "0: the root has an external leaf (depth 1), clean"

"$PHYS" "$IMG" 1 $((TOT + 1000)) index0 >/dev/null
blockdev --flushbufs "$DEV"
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
grep -q "root data lba" <<<"$OUT" && { fail "1 setup: the root is still at depth 0 (the poke moved its data extent)"; ct_exit; }
[ "$rc" = 1 ] && grep -q "root external extent leaf block $((TOT + 1000)) is outside" <<<"$OUT" &&
    pass "1: reported as damage, exit 1" || fail "1: exit $rc: $(grep -m1 -E 'ERR|pread|OK' <<<"$OUT")"
losetup -d "$DEV"
ct_exit
