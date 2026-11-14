#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group recount reads each group's bitmap as one batch
#
# A Zone Group claim and the mount's re-attach recount every member
# Block Group from its bitmap. Each bitmap block was its own serial
# device read -- eight per 1 GiB group, with a descriptor read and a CAW
# beside them, all under alloc_mutex: ~3 minutes per Zone Group at
# 64 TiB, and the mount of a restarted host serving nothing meanwhile
# (audit 2026-11-14 P3). The bitmap is now read forced-fresh as one
# batch per group (cetrafs_bg_prefetch_bitmap()), counted word-wise, and
# a recount of a Zone Group not cached yet runs outside alloc_mutex.
#
# A volume of 1 GiB groups (8 bitmap blocks each) is mounted, and the
# loop device's completed read requests over the mount are counted: the
# batch is one request per group where it was eight. The counts must
# agree either way: the same free figure, fsck clean.
#
# DISCRIMINATION: reconcile_serial reads block by block, under the
# mutex, as before; the mount then makes at least six more requests per
# group.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reconcile_serial ] || { skip "reconcile_serial is missing"; ct_exit; }
IMG="$(ct_image 8192 zgrb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgrb)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 1024 -J 0 -N 1024 -f >/dev/null
ct_param_set reconcile_serial 0
LOOP="$(basename "$DEV")"
reads() { awk '{print $1}' "/sys/block/$LOOP/stat"; }
NBG="$(ct_fsck "$DEV" 2>&1 | sed -n 's/.*block_group_count[ =:]*\([0-9]*\).*/\1/p' | head -1)"
[ -n "$NBG" ] || NBG=7

# <serial 0|1> -> "<read requests over the mount> <free_data_blocks>"
mount_reads() {
    local r0 r1 f
    echo "$1" >/sys/module/cetrafs/parameters/reconcile_serial
    echo 3 >/proc/sys/vm/drop_caches
    r0="$(reads)"
    ct_mount "$DEV" "$MNT"
    r1="$(reads)"
    f="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$DEV")/info")"
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/reconcile_serial
    echo "$((r1 - r0)) $f"
}
ct_mount "$DEV" "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=1M count=64 conv=fsync status=none
ct_umount "$MNT"

read -r RB FB <<<"$(mount_reads 0)"
read -r RS FS <<<"$(mount_reads 1)"
log "$NBG group(s): mount made $RB read request(s) batched, $RS serial; free $FB / $FS"
[ "$FB" = "$FS" ] && [ -n "$FB" ] && pass "the batched recount agrees with the serial one ($FB free)" ||
    fail "the batched recount gives $FB free, the serial one $FS"
[ "$RS" -ge $((RB + 6 * NBG)) ] && pass "the mount's recount reads a group's bitmap in one request ($RB vs $RS serial)" ||
    fail "the mount made $RB read requests batched against $RS serial -- the bitmaps are not read as one batch"
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$out" && fail "fsck: $(grep '^ERR' <<<"$out" | head -3)" || pass "fsck clean"
ct_exit
