#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# on a grown volume an extent may not aim at the Block Group table
#
# extent_phys_guard.sh covers the fixed tables below bg_regions_start.
# A grow appends Block Group table segments elsewhere: in a reserve at
# the end of the device, past the data area. The NEXT grow places its
# Block Groups past that reserve, so the first reserve becomes a hole
# INSIDE the data area's bounding box -- still holding a live segment,
# descriptors every node compare-and-swaps. cetrafs_lba_run_is_data()
# accepted [bg_regions_start, total_blocks), so an extent aimed at that
# segment (or at the current reserve past bg_data_end) passed, and a
# write(2) landed on the descriptors.
#
# Twice-grown image; a file's inline extent is pointed at each segment
# header in turn, then at the device's last block (past bg_data_end:
# no Block Group's data); a write through it must leave that block's
# bytes unchanged and the volume mountable.
#
# DISCRIMINATION: without cetrafs_sb_lba_run_hits_bg_table() the first
# segment is overwritten and the next mount refuses the chain; without
# the bg_data_end bound the device's last block is written (the tail
# segment is refused by name either way).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_big_image 1800 extgrown)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt extgrown)"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_growfs "$DEV" -s 1150M >/dev/null 2>&1 || { fail "setup: the first grow failed"; ct_exit; }
ct_growfs "$DEV" -s 1700M >/dev/null 2>&1 || { fail "setup: the second grow failed"; ct_exit; }
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the twice-grown volume is not clean"; ct_exit; }

# target <name>: point a fresh file at segment <name>, write through it.
target() {
    local name="$1" F INO POKED SEG BEFORE AFTER
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    F="$MNT/victim.$name"
    dd if=/dev/zero of="$F" bs=4096 count=1 conv=fsync status=none
    INO="$(stat -c %i "$F")"
    ct_umount "$MNT"

    POKED="$("$PPOKE" "$IMG" "$INO" "$name")" ||
        { fail "setup: could not aim the extent at $name: $POKED"; return; }
    SEG="$(echo "$POKED" | sed -n 's/.*-> \([0-9][0-9]*\) .*/\1/p')"
    blockdev --flushbufs "$DEV"
    BEFORE="$(dd if="$IMG" bs=4096 skip="$SEG" count=1 status=none | sha256sum)"
    log "$name: the extent now names block $SEG"

    ct_mount "$DEV" "$MNT"
    dd if=/dev/urandom of="$F" bs=4096 count=1 conv=notrunc status=none 2>/dev/null || true
    sync
    ct_umount "$MNT"
    AFTER="$(dd if="$IMG" bs=4096 skip="$SEG" count=1 status=none | sha256sum)"
    [ "$AFTER" = "$BEFORE" ] &&
        pass "$name: block $SEG is byte-identical after writing through the extent" ||
        fail "$name: the write reached block $SEG"

    if ct_mount "$DEV" "$MNT" 2>/dev/null; then
        pass "$name: the volume still mounts"
        rm -f "$F"
        ct_umount "$MNT"
    else
        fail "$name: the volume no longer mounts -- the chain was overwritten"
    fi
}

target bg_seg_first
target bg_seg_tail
target device_end

# The poked files are gone: nothing should be left to complain about.
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
