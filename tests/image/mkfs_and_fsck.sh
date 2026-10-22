#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs geometry, checksums, and what fsck catches on a raw image
#
# No kernel module and nothing mounted: purely what mkfs.cetra writes and
# what fsck.cetra makes of it. Covers the geometry auto-tunes (BG size on a
# small device, the -z clamp to the real BG count), the ZG<->BG ownership
# map, and -- with a negative control for each -- the BG descriptor, BG
# header, root inode and Node Registry checksums.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

ct_build
IMG="$(ct_image 560 main)"
LOOPDEV="$(ct_loop "$IMG")"
log "using $IMG (560 MiB sparse) on $LOOPDEV"

log "mkfs ($LOOPDEV)"
"$ROOT/userspace/mkfs.cetra" "$LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f

log "fsck"
if "$ROOT/userspace/fsck.cetra" "$LOOPDEV"; then
    pass "fsck reports a clean filesystem"
else
    fail "fsck reported errors"
fi

log "checking BG descriptor/header checksums catch corruption"
CORRUPT_IMG="$(mktemp /tmp/cetrafs-corrupt-XXXXXX.img)"
truncate -s 560M "$CORRUPT_IMG"
CORRUPT_LOOPDEV="$(losetup --find --show "$CORRUPT_IMG")"
"$ROOT/userspace/mkfs.cetra" "$CORRUPT_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

# BG table is at LBA 2 for this exact geometry (1 ZG, 1 BG) -- flip a byte
# well inside the BG descriptor's pad[] region (never inspected
# field-by-field), so only the new checksum can catch it.
printf '\xFF' | dd of="$CORRUPT_LOOPDEV" bs=1 seek=$((2 * 4096 + 200)) count=1 conv=notrunc status=none
if "$ROOT/userspace/fsck.cetra" "$CORRUPT_LOOPDEV" >/dev/null 2>&1; then
    fail "fsck did not detect a corrupted BG descriptor pad byte"
else
    pass "fsck detects a corrupted BG descriptor pad byte"
fi

# re-mkfs so this check is independent of the descriptor corruption above
# (fsck checks the descriptor before the header, so a still-corrupted
# descriptor would mask a header-only failure).
MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$CORRUPT_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f)"

# BG header lives at bg_regions_start -- read it from mkfs's own summary
# rather than hardcoding it, since it shifts whenever anything earlier in
# the fixed-metadata layout (inode table, Node Registry, ...) changes
# size. Flip a
# byte in the header's pad[] region.
BG_REGIONS_LBA="$(echo "$MKFS_OUT" | grep -oP 'BG regions start: LBA \K[0-9]+')"
printf '\xFF' | dd of="$CORRUPT_LOOPDEV" bs=1 seek=$((BG_REGIONS_LBA * 4096 + 200)) count=1 conv=notrunc status=none
if "$ROOT/userspace/fsck.cetra" "$CORRUPT_LOOPDEV" >/dev/null 2>&1; then
    fail "fsck did not detect a corrupted BG header pad byte"
else
    pass "fsck detects a corrupted BG header pad byte"
fi

log "checking root inode checksum catches corruption"
# re-mkfs so this check is independent of the BG corruptions above
MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$CORRUPT_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f)"

# Inode table LBA, read from mkfs's summary rather than hardcoded (see the
# BG-header test above for why). Root inode (#1) is the first record in
# it. Flip a byte in 'reserved' (offset 68), a field no code reads or
# writes, so only the new inode checksum can catch it.
INODE_TABLE_LBA="$(echo "$MKFS_OUT" | grep -oP 'inode_table: LBA \K[0-9]+')"
printf '\xFF' | dd of="$CORRUPT_LOOPDEV" bs=1 seek=$((INODE_TABLE_LBA * 4096 + 68)) count=1 conv=notrunc status=none
if "$ROOT/userspace/fsck.cetra" "$CORRUPT_LOOPDEV" >/dev/null 2>&1; then
    fail "fsck did not detect a corrupted root inode reserved byte"
else
    pass "fsck detects a corrupted root inode reserved byte"
fi

log "checking ZG<->BG ownership with multiple ZGs and BGs"
# -z 5 over a 2200M image at the default 512M BG size produces 4 BGs
# spread across 5 ZGs (first 4 ZGs get one BG each, the 5th gets none).
# fsck cross-checks first_bg_id/
# bg_count contiguity, each BG's owner_zg, and each ZG's free_data_blocks
# aggregate against its member BGs.
MULTIZG_IMG="$(mktemp /tmp/cetrafs-multizg-XXXXXX.img)"
truncate -s 2200M "$MULTIZG_IMG"
MULTIZG_LOOPDEV="$(losetup --find --show "$MULTIZG_IMG")"
"$ROOT/userspace/mkfs.cetra" "$MULTIZG_LOOPDEV" -z 5 -b 512 -J 0 -N 4096 -f >/dev/null
if "$ROOT/userspace/fsck.cetra" "$MULTIZG_LOOPDEV" >/dev/null 2>&1; then
    pass "fsck accepts a multi-ZG/multi-BG filesystem's ZG<->BG ownership"
else
    fail "fsck rejected a freshly-mkfs'd multi-ZG/multi-BG filesystem"
fi
losetup -d "$MULTIZG_LOOPDEV"
rm -f "$MULTIZG_IMG"

log "checking mkfs auto-sizes the default BG size on a small device"
# On a small device, the flat 1 GiB default BG size can waste a large
# fraction of capacity to rounding (no partial trailing BG exists) --
# e.g. a 5G device with -z 2 and no -b/-J only fit 4 whole 1 GiB BGs
# (4G usable, 18% wasted) before mkfs started auto-tuning its defaults.
# Omitting -b/-J here deliberately, to exercise that auto-tuning rather
# than the explicit sizes every other mkfs call in these suites uses.
SMALL_IMG="$(mktemp /tmp/cetrafs-small-XXXXXX.img)"
truncate -s 5G "$SMALL_IMG"
SMALL_LOOPDEV="$(losetup --find --show "$SMALL_IMG")"
SMALL_MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$SMALL_LOOPDEV" -z 2 -N 4096 -f)"

SMALL_BG_MIB="$(echo "$SMALL_MKFS_OUT" | grep -oP '\(\K[0-9]+(?= MiB\))')"
[ "$SMALL_BG_MIB" = "512" ] && pass "mkfs auto-tuned a 5G device down to a 512 MiB BG size (from the 1024 MiB default)" ||
    fail "mkfs picked a $SMALL_BG_MIB MiB BG size on a 5G device, expected 512"

if "$ROOT/userspace/fsck.cetra" "$SMALL_LOOPDEV" >/dev/null 2>&1; then
    pass "fsck accepts the auto-sized small-device filesystem"
else
    fail "fsck rejected the auto-sized small-device filesystem"
fi

losetup -d "$SMALL_LOOPDEV"
rm -f "$SMALL_IMG"

log "checking the Node Registry table round-trips and catches corruption"
# re-mkfs so this check is independent of the prior corruptions above
MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$CORRUPT_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f)"

if "$ROOT/userspace/fsck.cetra" "$CORRUPT_LOOPDEV" >/dev/null 2>&1; then
    pass "fsck accepts a freshly-mkfs'd (all-FREE) Node Registry table"
else
    fail "fsck rejected a freshly-mkfs'd Node Registry table"
fi

# Node table LBA shifts whenever the inode table's size does (it's sized
# from -N and sizeof(cetrafs_inode_t)), so read it from mkfs's own summary
# rather than hardcoding it -- the BG-header test above just got bitten by
# exactly this. Slot 0's 'state' field sits right after the 16-byte
# node_uuid; flipping it away from CETRAFS_NODE_STATE_FREE (0) without a
# matching checksum exercises the same CRC path a real corrupted/half-
# written registration would hit.
NODE_TABLE_LBA="$(echo "$MKFS_OUT" | grep -oP '^  node_table: LBA \K[0-9]+')"
printf '\x63\x00\x00\x00' | dd of="$CORRUPT_LOOPDEV" bs=1 seek=$((NODE_TABLE_LBA * 4096 + 16)) count=4 conv=notrunc status=none
if "$ROOT/userspace/fsck.cetra" "$CORRUPT_LOOPDEV" >/dev/null 2>&1; then
    fail "fsck did not detect a corrupted Node Registry slot"
else
    pass "fsck detects a corrupted Node Registry slot"
fi

losetup -d "$CORRUPT_LOOPDEV"
rm -f "$CORRUPT_IMG"



log "checking mkfs refuses what the format cannot represent"
# The superblock stores the inode count in a __le32 while the inode
# table is SIZED from the value given. Before this check, -N 4294967400
# reserved 4294967400 blocks (16 TiB) of table on a volume whose
# superblock then claimed 104 inodes -- and the kernel's layout check
# passes, because 104 does fit in 4294967400 blocks. A value the format
# cannot hold has to fail at format time, exactly as -M above 64 does.
# It has to be asked on a device big enough to BACK that many inodes:
# on a small one the geometry solve refuses first ("no space for any
# BG") and the bound is never reached, so the assertion would pass
# against a build without it. Measured -- that is exactly what the first
# version of this check did.
BOUND_DEV="$(ct_huge_dev 17 bound)"
if [ -z "$BOUND_DEV" ]; then
    skip "device-mapper is unavailable; the 32-bit inode bound cannot be reached on a small device"
else
    # Dry run: accepting this would otherwise try to write a 16 TiB
    # inode table.
    if "$ROOT/userspace/mkfs.cetra" "$BOUND_DEV" -b 131072 -z 8 -J 0 -M 4 -N 4294967400 -f -n >/dev/null 2>&1; then
        fail "mkfs accepted -N 4294967400, which the superblock truncates to 104"
    else
        pass "mkfs refuses an inode count the superblock cannot store"
    fi
    # ...and the largest value that DOES fit is not caught by the same
    # check, so the bound is a bound rather than a blanket.
    OUT="$("$ROOT/userspace/mkfs.cetra" "$BOUND_DEV" -b 131072 -z 8 -J 0 -M 4 -N 4294967295 -f -n 2>&1 || true)"
    case "$OUT" in
    *"too large"*) fail "the 32-bit bound rejected the largest value that DOES fit" ;;
    *) pass "the largest representable inode count passes the bound" ;;
    esac
fi

ct_exit
