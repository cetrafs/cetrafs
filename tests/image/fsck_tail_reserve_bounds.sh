#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck bounds the tail reserve as the kernel does, not more loosely
#
# The kernel refuses a superblock whose tail reserve is not between the
# data area and the end of the volume, with an overflow-checked sum
# (fs.c cetrafs_layout_bounds_check()). fsck only asked that start +
# length not exceed total_blocks: a reserve over the data area, or one
# whose length wraps the sum past 2^64, read as clean -- a volume no
# node will mount, which fsck calls OK (audit 2026-11-11 F4).
#
#  0. a grown volume (a real tail reserve) is clean.
#  1. the reserve moved into the data area: fsck refuses it.
#  2. a length that wraps start + length: fsck refuses it.
#
# DISCRIMINATION (2026-11-11, fsck.c before this fix): 1 and 2 exit 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
field() { "$SBPOKE" "$DEV" | sed -n "s/^$1=//p"; }

IMG="$(ct_image 600 tailres)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
losetup -d "$DEV"; truncate -s 1200M "$IMG"; DEV="$(ct_loop "$IMG")"
"$ROOT/userspace/growfs.cetra" "$DEV" >/dev/null 2>&1 || { fail "setup: growfs failed"; ct_exit; }
TS="$(field tail_reserve_start)"; TB="$(field tail_reserve_blocks)"; RS="$(field bg_regions_start)"
[ -n "$TS" ] && [ "$TS" != 0 ] && [ "$TB" != 0 ] || { fail "setup: the grow left no tail reserve ($TS +$TB)"; ct_exit; }
ct_fsck "$DEV" >/dev/null 2>&1 && pass "0: the grown volume (reserve [$TS +$TB)) is clean" ||
    { fail "0 setup: the grown volume is not clean"; ct_exit; }

log "1: tail_reserve_start = bg_regions_start ($RS), inside the data area"
"$SBPOKE" "$DEV" tail_reserve_start "$RS" >/dev/null
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "tail reserve" <<<"$OUT" && pass "1: refused: $(grep -m1 'tail reserve' <<<"$OUT")" ||
    fail "1: fsck exit $rc: $(tail -1 <<<"$OUT")"
"$SBPOKE" "$DEV" tail_reserve_start "$TS" >/dev/null

log "2: tail_reserve_blocks wraps start + length"
"$SBPOKE" "$DEV" tail_reserve_blocks "$((-TS + 1))" >/dev/null # strtoull: 2^64 - TS + 1
[ "$(field tail_reserve_blocks)" = "$(python3 -I -c "print(2**64 - $TS + 1)")" ] ||
    { fail "2 setup: the wrapping length was not written: $(field tail_reserve_blocks)"; ct_exit; }
rc=0; OUT="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "tail reserve" <<<"$OUT" && pass "2: refused: $(grep -m1 'tail reserve' <<<"$OUT")" ||
    fail "2: fsck exit $rc: $(tail -1 <<<"$OUT")"
"$SBPOKE" "$DEV" tail_reserve_blocks "$TB" >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 && pass "restored: clean again" || fail "the restored volume is not clean"
losetup -d "$DEV"
ct_exit
