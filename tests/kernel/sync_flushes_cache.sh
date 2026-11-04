#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# sync(2), syncfs(2) and unmount flush the device's write cache
#
# Only fsync and the journal issued a cache flush. ->sync_fs flushed the
# allocation bitmaps and counters and returned, and the VFS's own
# sync_blockdev() waits for completion and flushes nothing -- so on a
# volatile write cache (the deployment LUN may be write-back) sync,
# syncfs and umount returned with data and metadata in the cache, where
# a power cut loses them.
#
# The block layer counts flush requests per device (field 16 of
# /sys/block/<dev>/stat), which a loop device reports too. A syncfs
# after a buffered write, and an unmount, must each issue at least one.
#
# DISCRIMINATION: without the flushes the syncfs issues none.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 syncflush)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt syncflush)"
ct_mkfs_small "$DEV" >/dev/null
ST="/sys/block/$(basename "$DEV")/stat"
[ "$(wc -w <"$ST")" -ge 17 ] || { skip "this kernel does not count flush requests in $ST"; ct_exit; }
flushes() { awk '{ print $16 }' "$ST"; }
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

# Nothing else may be flushing while we count: let the mount settle.
sleep 2
dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 status=none
B="$(flushes)"
sync -f "$MNT"
A="$(flushes)"
[ "$A" -gt "$B" ] && pass "syncfs issued $((A - B)) cache flush(es)" ||
    fail "syncfs returned without a single cache flush ($B -> $A): the data may still be in a volatile cache"

B="$(flushes)"
ct_umount "$MNT"
A="$(flushes)"
[ "$A" -gt "$B" ] && pass "unmount issued $((A - B)) cache flush(es)" ||
    fail "unmount returned without a cache flush ($B -> $A)"
ct_exit
