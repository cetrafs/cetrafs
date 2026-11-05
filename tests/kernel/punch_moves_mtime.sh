#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a hole punch moves mtime as well as ctime
#
# A punch changes the file's contents, and a tool that decides what to
# copy by mtime (rsync, a backup) has nothing else to go by. cetrafs
# moved ctime only, and a punch that freed no whole block -- only zeroed
# part of one -- moved neither (audit L24). ext4 and XFS move both.
#
# DISCRIMINATION: on the unfixed code both mtimes stay where touch -d
# put them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 punchmt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt punchmt)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

for f in whole part; do
    dd if=/dev/urandom of="$MNT/$f" bs=4096 count=4 conv=fsync status=none
    touch -d '2001-01-01 00:00:00' "$MNT/$f"
done
OLD="$(stat -c %Y "$MNT/whole")"
fallocate -p -o 4096 -l 8192 "$MNT/whole"   # two whole blocks
fallocate -p -o 100 -l 200 "$MNT/part"      # inside one block: zeroing only
for f in whole part; do
    M="$(stat -c %Y "$MNT/$f")"
    [ "$M" -gt "$OLD" ] && pass "$f-block punch moved mtime" ||
        fail "$f-block punch left mtime at $(date -d "@$M" +%F)"
done
# ...and durably: what a peer or the next mount reads.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
for f in whole part; do
    M="$(stat -c %Y "$MNT/$f")"
    [ "$M" -gt "$OLD" ] && pass "$f: the new mtime is on the device" || fail "$f: the device still has the old mtime"
done
ct_umount "$MNT"
ct_exit
