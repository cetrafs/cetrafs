#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a BG's free-block delta rolls up into its owning ZG's aggregate
#
# fsck cross-checks that a ZG's free_data_blocks equals the sum of its
# BGs'. Before the rollup existed a partial punch updated the BG and left
# the ZG frozen at its mkfs-time value.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking the ZG free_data_blocks aggregate rollup"
# Independent throwaway image, same pattern as the other blocks above.
#
# Regression test for a real gap: alloc.c's cetrafs_bg_adjust_free_blocks()
# used to update
# a BG's own free_data_blocks but never roll that delta up into the
# owning ZG's own cached aggregate, so fsck's "ZG free_data_blocks ==
# sum of its BGs'" cross-check would fail the moment a real net space
# change happened. kernel/punch_hole.sh never caught this
# because a *full*-file punch frees every block the file owned, netting
# back to the pristine all-free state the ZG aggregate already had from
# mkfs -- indistinguishable from "working" by coincidence. A *partial*
# punch (real net space freed, not a round trip to zero) is what
# actually exercises the rollup. Fixed by zonegroup.c's new
# cetrafs_zg_adjust_free_blocks(), called from cetrafs_bg_adjust_free_
# blocks() via the BG descriptor's own owner_zg field.
ZGAGG_IMG="$(mktemp /tmp/cetrafs-zgagg-XXXXXX.img)"
truncate -s 560M "$ZGAGG_IMG"
ZGAGG_LOOPDEV="$(losetup --find --show "$ZGAGG_IMG")"
ZGAGG_MNT="$(mktemp -d /tmp/cetrafs-zgagg-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$ZGAGG_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$ZGAGG_LOOPDEV" "$ZGAGG_MNT"
require_cetrafs_mount "$ZGAGG_MNT"

dd if=/dev/zero bs=4096 count=256 2>/dev/null | tr '\0' 'A' > "$ZGAGG_MNT/zgaggfile"
sync

# Partial punch: a real, permanent net reduction in blocks in use (not
# a full-file punch, which nets back to zero and never exposed this).
fallocate --punch-hole --keep-size --offset 4096 --length 409600 "$ZGAGG_MNT/zgaggfile"

umount "$ZGAGG_MNT"

ZGAGG_FSCK_OUT="$("$ROOT/userspace/fsck.cetra" "$ZGAGG_LOOPDEV" 2>&1)"
ZGAGG_FSCK_RC=$?
# (fsck's cache-vs-cache "sum of its BGs" structural check was
# removed -- a crash between the two counts' separate CAS flushes made it a
# false fatal. The content pass's bitmap-truth message is what fires now.)
echo "$ZGAGG_FSCK_OUT" | grep -qE "free_data_blocks.*!= .*(sum of its BGs|actually free)" &&
    fail "ZG aggregate: fsck caught a stale ZG free_data_blocks aggregate after a partial punch: $ZGAGG_FSCK_OUT"
[ "$ZGAGG_FSCK_RC" -eq 0 ] && pass "ZG aggregate: fsck.cetra is clean after a partial punch left a real net free-block change" ||
    fail "ZG aggregate: fsck.cetra reported an unrelated problem: $ZGAGG_FSCK_OUT"

rmdir "$ZGAGG_MNT"
losetup -d "$ZGAGG_LOOPDEV"
rm -f "$ZGAGG_IMG"


ct_exit
