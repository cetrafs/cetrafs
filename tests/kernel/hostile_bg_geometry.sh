#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Block Group descriptor with an impossible geometry is refused, not used
#
# The kernel checked a BG descriptor's checksum and nothing else, while
# its offsets aim I/O: the allocator and the bitmap flush address bitmap
# blocks from start_block + off_data_bmap, data goes to start_block +
# off_data_region, the flush walks off_data_region - off_data_bmap blocks
# in u32, and the scrub sizes a buffer from data_block_count.
# cetrafs.h said descriptors were "checked when read"; only the checksum
# was. Each case restamps the checksum, so the geometry check is the only
# thing between the descriptor and the I/O it aims.
#
#  A. start_block moved so BG 0's bitmap lands on the inode table: the
#     allocator's bitmap writes and the data then land on the global
#     tables (the case run on the old code -- the others would wedge it);
#  B. off_data_bmap past off_data_region: the u32 walk wraps to ~4e9;
#  C. data_block_count past what the bitmap can describe.
#
# DISCRIMINATION (measured on the old code, case A only): the inode table
# is rewritten.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 hbg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hbg)"
field() { "$BG_POKE" "$IMG" 0 --dump | grep -oP "$1=\K[0-9]+"; }

attempt() { # <label> -> mounts, writes, syncs; passes only if the geometry was refused
    local mark rc=0 out
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        timeout 60 dd if=/dev/urandom of="$MNT/f" bs=64k count=32 conv=fsync status=none 2>/dev/null || rc=$?
        timeout 60 sync || true
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    fi
    out="$(dmesg_since "$mark")"
    grep -q "describes an impossible Block Group" <<<"$out" &&
        pass "$1: the descriptor was refused" ||
        fail "$1: an impossible BG geometry was used (write rc=$rc)"
}

for case in A B C; do
    ct_mkfs_small "$DEV" >/dev/null
    ITS="$(field inode_table_start)"
    BMAP="$(field off_data_bmap)"
    REGION="$(field off_data_region)"
    COUNT="$(field data_block_count)"
    ITAB_BEFORE="$(dd if="$IMG" bs=4096 skip="$ITS" count=64 status=none | sha256sum | cut -d' ' -f1)"
    case "$case" in
    A)
        "$BG_POKE" "$IMG" 0 --geom=start_block $((ITS - BMAP)) >/dev/null
        attempt "A (bitmap aimed at the inode table)"
        [ "$(dd if="$IMG" bs=4096 skip="$ITS" count=64 status=none | sha256sum | cut -d' ' -f1)" = "$ITAB_BEFORE" ] &&
            pass "A: the inode table was not written through the descriptor" ||
            fail "A: the inode table was rewritten through BG 0's descriptor"
        ;;
    B)
        "$BG_POKE" "$IMG" 0 --geom=off_data_bmap $((REGION + 1)) >/dev/null
        attempt "B (bitmap offset past the data offset)"
        ;;
    C)
        "$BG_POKE" "$IMG" 0 --geom=data_block_count $(((REGION - BMAP) * 4096 * 8 + 1)) >/dev/null
        attempt "C (more data blocks than the bitmap describes)"
        ;;
    esac
done
ct_exit
