#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a checksum-valid extent longer than the device must not be acted on
#
# Found by fuzz mount-fields (seed 68728367, iter 121) during a release
# matrix run: a mutated-but-restamped inode record claimed an extent of
# 1302593496 blocks -- about 5 TiB -- on a 560 MiB image. The record
# passed every integrity check, so the preallocated-extent split path
# accepted it and began releasing the "tail" one block at a time:
#
#   cetrafs: extent leaf full splitting a preallocated extent:
#            releasing 1302593496 preallocated block(s) at 11992
#
# 1.3 billion calls to cetrafs_free_data_block(), reported by the fuzzer
# as "op hang: write-exercise". The loop was bounded by a number the
# device cannot back; it is now bounded by the device.
#
# Discrimination: remove the bounds check from
# cetrafs_leaf_array_convert() and the write below never returns.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 extlen)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt extlen)"
POKE="$(ct_helper inode_block_poke)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

dd if=/dev/zero of="$MNT/f" bs=4096 count=4 conv=fsync status=none
sync
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"

# A peer could never write this, but a corrupted record can hold it and
# still pass its checksum -- which is exactly what the fuzzer produced.
"$POKE" "$IMG" extlen "$INO" 1302593496 >/dev/null 2>&1 || fail "could not set the absurd extent length"

ct_mount "$DEV" "$MNT"
# Writing into the preallocated range is what drives the split. With no
# bound this never returns; the timeout is the assertion.
# "|| RC=$?", not a bare call: under set -e the nonzero exit we are
# testing for would kill the suite before RC could be read.
RC=0
timeout 25 dd if=/dev/zero of="$MNT/f" bs=4096 count=1 seek=1 conv=notrunc status=none 2>/dev/null || RC=$?
log "write against a 1302593496-block extent returned rc=$RC"
[ "$RC" != 124 ] || fail "the write HUNG -- the split is still walking an extent the device cannot back"

dmesg | tail -40 | grep -q "does not fit the volume" ||
    log "note: no bounds message in dmesg (the write may have been refused earlier)"

# The filesystem must still be usable, not wedged.
ls "$MNT" >/dev/null || fail "the mount is unusable after refusing the corrupt extent"
ct_umount "$MNT"

pass "a checksum-valid extent longer than the device is refused, not walked"

ct_exit
