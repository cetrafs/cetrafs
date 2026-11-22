#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports a file size past the format's ceiling, and -r sets it to the ceiling
#
# The kernel refuses a record whose size is past what the format can
# address (cetrafs_size_sane(), -EUCLEAN on every node): the file is
# unreachable cluster-wide. fsck never looked, and reported such a volume
# clean (audit 2026-11-22 N-47). The ceiling is now one constant in
# cetrafs.h; fsck reports a size past it, and -r sets it to the ceiling
# -- no extent addresses a byte past it, so nothing readable is lost.
#
# Staged on an image: a regular-file record planted at inode 5, its bit
# set, size 2^62 (past the 2^60 ceiling). Then:
#   1. fsck: nonzero, names the size;
#   2. fsck -r: sets it to the ceiling (the record's size reads back so);
#   3. fsck: clean (the unnamed file has gone to /lost+found).
#
# DISCRIMINATION: the control, in-suite --
# CETRAFS_FSCK_TEST_SIZE_UNCHECKED=1, the old pass: nothing is said about
# the size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
IPOKE="$(ct_helper inode_block_poke)"
SBPOKE="$(ct_helper sb_poke)"
BMAP="$(ct_helper bmap_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 600 fszc)"
DEV="$(ct_loop "$IMG")"
CEIL=$((1 << 60))
SAID="inode 5 has size $((1 << 62)), past the format's $CEIL-byte ceiling"

ct_mkfs "$DEV" -N 1024 -f >/dev/null
"$IPOKE" "$IMG" plantrec 5 0100644 2>/dev/null
"$IPOKE" "$IMG" nlink 5 1 2>/dev/null
"$IPOKE" "$IMG" setsize 5 $((1 << 62)) 2>/dev/null
"$BMAP" "$DEV" "$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')" 4 1 >/dev/null
blockdev --flushbufs "$DEV"
[ "$("$IPOKE" "$IMG" size 5 2>/dev/null)" = $((1 << 62)) ] && pass "setup: inode 5 is a file of size 2^62" ||
    { fail "setup: inode 5's size is $("$IPOKE" "$IMG" size 5 2>/dev/null)"; ct_exit; }

OUT="$(CETRAFS_FSCK_TEST_SIZE_UNCHECKED=1 "$FSCK" "$DEV" 2>&1 || true)"
grep -q "$SAID" <<<"$OUT" && fail "control: the old pass named the size -- the knob does not reach the check" ||
    pass "control: the old pass says nothing about the size"

RC=0
OUT="$("$FSCK" "$DEV" 2>&1)" || RC=$?
[ "$RC" != 0 ] && grep -q "$SAID" <<<"$OUT" && pass "fsck reports the size past the ceiling (exit $RC)" ||
    fail "fsck on the size past the ceiling: exit $RC, $(grep -E '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')"
OUT="$("$FSCK" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
S="$("$IPOKE" "$IMG" size 5 2>/dev/null)"
[ "$S" = "$CEIL" ] && grep -q "set inode 5's size to the format's ceiling" <<<"$OUT" &&
    pass "fsck -r set the size to the ceiling ($S)" || fail "after fsck -r inode 5's size is $S"
OUT="$("$FSCK" "$DEV" 2>&1)" && pass "fsck clean after the repair" ||
    fail "still dirty: $(grep -E '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')"
ct_exit
