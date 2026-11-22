#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck walks a long inode table chain without overrunning its segment list
#
# fsck collects every appended table segment's [header, end) into one
# pair of arrays, sized 2 * (block_group_count + 1) on the reasoning that
# each grow appends at most one segment to each chain and adds at least
# one Block Group. The Block Group chain obeys that; the inode chain does
# not -- an inode-only grow (growfs -N) appends an inode segment and no
# Block Group, and an image can link up to CETRAFS_ISEG_MAX (1024)
# one-inode segments behind a one-group volume. The walk appended to the
# arrays with no capacity check: about 1,000 attacker-chosen pairs
# written past a 4-slot heap allocation, before any repair and without
# -r (audit 2026-11-22 N-1).
#
# A one-group volume gets a chain of 1,000 one-inode segments
# (iseg_chain_poke), under the 1024 cap so the walk accepts every one.
# fsck is built with AddressSanitizer for this suite, because a heap
# overrun is otherwise silent: the plain binary went on to report other
# damage and exit 1, exactly as it does with the fix.
#   1. setup: the volume has exactly one Block Group, and the plain
#      fsck walks the chain (the cap is not named);
#   2. the sanitised fsck finishes with no AddressSanitizer report;
#   3. a chain over the cap (1,100) is still refused by name.
#
# DISCRIMINATION (measured on the unfixed code): check 2 fails with
# "heap-buffer-overflow" in fsck_chain_walk.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
ICP="$(ct_helper iseg_chain_poke)"

ASAN="$CT_BUILD/fsck-asan"
mkdir -p "$CT_BUILD"
if [ ! -x "$ASAN" ] || [ "$ROOT/userspace/fsck.c" -nt "$ASAN" ] || [ "$ROOT/include/cetrafs.h" -nt "$ASAN" ] ||
    [ "$ROOT/userspace/devutil.h" -nt "$ASAN" ]; then
    cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O1 -g -std=gnu99 \
        -fsanitize=address -fno-omit-frame-pointer -o "$ASAN" "$ROOT/userspace/fsck.c" ||
        { fail "setup: cannot build fsck with AddressSanitizer"; ct_exit; }
fi

# chain <segments> -> the device, a one-group volume with that chain linked
chain() {
    local img dev at
    img="$(ct_image 600 "fiscc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -s 560M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    at=$(("$("$SBPOKE" "$img" | sed -n 's/^bg_regions_start=//p')" + 2000))
    "$ICP" "$img" "$at" "$1" 1024 >/dev/null
    "$SBPOKE" "$img" inode_first_count 1024 >/dev/null
    "$SBPOKE" "$img" inode_seg_next "$at" >/dev/null
    "$SBPOKE" "$img" inodes_count $((1024 + $1)) >/dev/null
    blockdev --flushbufs "$dev"
    echo "$dev"
}

DEV="$(chain 1000)"
NBG="$("$SBPOKE" "$DEV" | sed -n 's/^block_group_count=//p')"
PLAIN="$(ct_fsck "$DEV" 2>&1 || true)"
if [ "$NBG" = 1 ] && ! grep -q "more than 1024 segments" <<<"$PLAIN"; then
    pass "1: setup: one Block Group, and fsck walks the 1,000-segment chain"
else
    fail "1: setup: block_group_count=$NBG, or the walk refused the chain -- nothing to measure"
    ct_exit
fi

OUT="$(ASAN_OPTIONS=detect_leaks=0:exitcode=99 "$ASAN" "$DEV" 2>&1)" && RC=0 || RC=$?
if [ "$RC" != 99 ] && ! grep -q "AddressSanitizer" <<<"$OUT"; then
    pass "2: the sanitised fsck walks the chain with no AddressSanitizer report (exit $RC)"
else
    fail "2: AddressSanitizer: $(grep -m1 -E 'ERROR: AddressSanitizer|SUMMARY' <<<"$OUT")"
fi

DEV="$(chain 1100)"
OUT="$(ASAN_OPTIONS=detect_leaks=0:exitcode=99 "$ASAN" "$DEV" 2>&1)" && RC=0 || RC=$?
if [ "$RC" != 99 ] && grep -q "^ERR: inode table chain has more than 1024 segments" <<<"$OUT"; then
    pass "3: a chain over the cap is still refused by name"
else
    fail "3: exit $RC: $(grep -m1 -E 'AddressSanitizer|ERR' <<<"$OUT")"
fi
ct_exit
