#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Block Group data regions start on the volume's data alignment, through mkfs and every grow
#
# Data started 9 blocks into each group, on no array's allocation unit or
# stripe, so an emptied group's UNMAP and every large write straddled
# the array's units (audit 2026-11-15, section 8). The superblock now
# carries data_align_blocks (mkfs -A, default 1 MiB): the first group
# starts on it, the group size is a multiple of it, and each group's
# data region starts on the next multiple past its header and bitmap.
#
#   A. default, -A 4096 and -A 4: every group's start and data start are
#      multiples of the alignment the superblock records (256, 1024, 1);
#      the span from the bitmap to the data is exactly the bitmap -- every
#      reader takes [off_data_bmap, off_data_region) as the bitmap, so the
#      alignment's gap must sit before it, never after; fsck clean.
#   B. mkfs refuses an alignment that is not a power of two, out of
#      range, or not dividing the group size; fsck refuses a superblock
#      carrying one (the mount: kernel/superblock_validation.sh).
#   C. a volume grown twice: the second grow's groups start past the
#      first grow's table segment, at a position that is NOT on the
#      alignment (asserted) -- and they are still aligned; fsck clean.
#
# DISCRIMINATION: A's -A 4 is the old layout and must read as unaligned
# to 1 MiB -- the measurement sees a misaligned group; C asserts its
# setup reaches an unaligned grow start.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
SBPOKE="$(ct_helper sb_poke)"
BG_POKE="$(ct_helper bg_poke)"
GROWFS="$ROOT/userspace/growfs.cetra"
IMG="$(ct_image 1200 dalign)"
sbf() { "$SBPOKE" "$1" | sed -n "s/^$2=//p"; }

# <dev> <align> -> "ok", or the first group that is not aligned to it, or
# whose bitmap does not end where its data starts
aligned_to() {
    local dev="$1" a="$2" n b d s o m l
    n="$(sbf "$dev" block_group_count)"
    for b in $(seq 0 $((n - 1))); do
        d="$("$BG_POKE" "$dev" "$b" --dump)"
        s="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
        o="$(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d")"
        m="$(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$d")"
        l="$(sed -n 's/.*length_blocks=\([0-9]*\).*/\1/p' <<<"$d")"
        if [ $((s % a)) != 0 ] || [ $(((s + o) % a)) != 0 ]; then
            echo "BG$b start=$s data=+$o"
            return
        fi
        if [ $((o - m)) != $(((l - 1 + 32768) / 32769)) ]; then
            echo "BG$b bitmap=+$m data=+$o: $((o - m)) blocks read as bitmap, $(((l - 1 + 32768) / 32769)) are"
            return
        fi
    done
    echo ok
}

DEV="$(ct_loop "$IMG")"
for c in "default 256" "4096 1024" "4 1"; do
    set -- $c
    if [ "$1" = default ]; then ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null; else
        ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -A "$1" -f >/dev/null; fi
    rec="$(sbf "$DEV" data_align_blocks)"
    [ "$rec" = "$2" ] || { fail "A $1: the superblock records $rec, not $2"; continue; }
    r="$(aligned_to "$DEV" "$2")"
    [ "$r" = ok ] && ct_fsck "$DEV" >/dev/null 2>&1 &&
        pass "A $1: every group and its data start on $2 blocks; fsck clean" || fail "A $1: $r"
    if [ "$1" = 4 ]; then
        r="$(aligned_to "$DEV" 256)"
        [ "$r" != ok ] && pass "A control: the unaligned layout reads as unaligned to 1 MiB ($r)" ||
            fail "A control: -A 4 reads as aligned to 1 MiB -- the check cannot see misalignment"
    fi
done

for bad in "-A 3" "-A 2" "-A 131072" "-b 600 -A 16384"; do
    rc=0
    # shellcheck disable=SC2086
    "$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 $bad -f >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] && pass "B: mkfs refuses $bad (2)" || fail "B: mkfs $bad exited $rc"
done
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
for v in 0 3 1048576; do
    "$SBPOKE" "$DEV" data_align_blocks "$v" >/dev/null
    blockdev --flushbufs "$DEV"
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    grep -q "ERR: data_align_blocks $v" <<<"$out" && pass "B: fsck refuses data_align_blocks=$v" ||
        fail "B: fsck on data_align_blocks=$v: $(grep -m1 -E 'ERR|clean' <<<"$out")"
done
losetup -d "$DEV"

# C. Grown twice, offline.
truncate -s 1200M "$IMG"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -A 4096 -f >/dev/null
losetup -d "$DEV"
for size in 2400M 3600M; do
    truncate -s "$size" "$IMG"
    DEV="$(ct_loop "$IMG")"
    if [ "$size" = 3600M ]; then
        rs="$(sbf "$DEV" tail_reserve_start)" rb="$(sbf "$DEV" tail_reserve_blocks)"
        GROW_AT=$((rs + rb))
    fi
    "$GROWFS" "$DEV" >/dev/null 2>&1 || fail "C: growfs to $size failed"
    losetup -d "$DEV"
done
DEV="$(ct_loop "$IMG")"
[ $((GROW_AT % 1024)) != 0 ] || fail "C: setup: the second grow would start on the alignment anyway ($GROW_AT)"
r="$(aligned_to "$DEV" 1024)"
[ "$r" = ok ] && ct_fsck "$DEV" >/dev/null 2>&1 &&
    pass "C: grown twice (the second from $GROW_AT), every group still aligned; fsck clean" || fail "C: $r"
losetup -d "$DEV"
ct_exit
