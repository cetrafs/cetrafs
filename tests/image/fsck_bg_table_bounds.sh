#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck refuses the Block Group table the mount refuses
#
# fsck's own checks on the Block Group table had fallen behind the
# mount's. It never compared a descriptor's bg_id with its place in the
# table (cetrafs_bg_geom_sane() refuses it), never asked where an
# appended segment sat (the mount refuses one among the fixed tables or
# inside a Block Group), and walked a segment's count before bounding
# it -- 2^32 descriptors spun the loop and wrapped its u32 cursor. A
# volume the mount refuses and fsck calls clean is one an operator has
# no tool to diagnose.
#
# Each case is one fault on a grown volume, CRC restamped so only the
# check under test can see it.
#
# DISCRIMINATION: without the new checks, A, C and D read clean and B
# spins for seconds before it fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SEG="$(ct_helper seg_poke)"
BGP="$(ct_helper bg_poke)"
SBP="$(ct_helper sb_poke)"

DEV="$(ct_big_dev 1400 fsckbgt)"
grown() {
    ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    ct_growfs "$DEV" >/dev/null 2>&1 || { fail "setup: growfs failed"; ct_exit; }
    "$SEG" "$DEV" dump | grep -q 'head=[1-9]' || { fail "setup: the grow left no appended segment"; ct_exit; }
    ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the grown volume is not clean"; ct_exit; }
}
expect() { # <label> <regex>
    local out t0 t1
    t0="$(date +%s%N)"
    out="$(timeout 60 "$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" && { fail "$1: fsck called it clean"; return; }
    t1="$(date +%s%N)"
    grep -qE "$2" <<<"$out" && pass "$1: refused ($(grep -m1 -E "$2" <<<"$out"))" ||
        fail "$1: fsck failed, but not on this: $(grep -m1 ERR <<<"$out")"
    [ $(((t1 - t0) / 1000000)) -lt 3000 ] || fail "$1: took $(((t1 - t0) / 1000000)) ms -- something walked a hostile count"
}

grown
"$BGP" "$DEV" 0 --geom=bg_id 1 >/dev/null
expect "A: descriptor 0 naming Block Group 1" 'descriptor says it is Block Group 1'

grown
"$SEG" "$DEV" count 4294967295 >/dev/null
expect "B: a segment claiming 2^32 descriptors" 'claims 4294967295'

grown
ITS="$("$BGP" "$DEV" 0 --dump | sed -n 's/.*inode_table_start=\([0-9][0-9]*\).*/\1/p')"
"$SEG" "$DEV" copyto $((ITS + 900)) >/dev/null
"$SBP" "$DEV" bg_table_next $((ITS + 900)) >/dev/null
expect "C: the segment on the inode table" 'among the fixed tables'

grown
B0="$("$BGP" "$DEV" 0 --dump)"
S0="$(sed -n 's/.*start_block=\([0-9][0-9]*\).*/\1/p' <<<"$B0")"
R0="$(sed -n 's/.*off_data_region=\([0-9][0-9]*\).*/\1/p' <<<"$B0")"
"$SEG" "$DEV" copyto $((S0 + R0 + 5000)) >/dev/null
"$SBP" "$DEV" bg_table_next $((S0 + R0 + 5000)) >/dev/null
expect "D: the segment inside Block Group 0" 'overlaps BG0'
ct_exit
