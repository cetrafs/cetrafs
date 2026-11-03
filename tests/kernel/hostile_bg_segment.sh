#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an appended Block Group table segment must lie where a grow puts one
#
# Only the first segment of the Block Group table goes through the
# superblock's region map. An appended one was checked for its magic,
# checksum, count and device bounds, not for WHERE it is: a segment on
# the inode table, or inside a Block Group, mounted -- and every later
# descriptor update (a free-count CAS, an ownership change) wrote into
# whatever was really there. A grow only ever places a segment in a tail
# reserve, past every fixed table and outside every Block Group.
#
#  A. the segment copied onto the inode table;
#  B. the segment copied into Block Group 0;
#  C. the segment where the grow put it (control).
#
# Each copy verifies in every byte: only its placement is wrong.
#
# DISCRIMINATION (measured on the old code): A and B mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SEG_POKE="$(ct_helper seg_poke)"
SB_POKE="$(ct_helper sb_poke)"
BG_POKE="$(ct_helper bg_poke)"

DEV="$(ct_big_dev 1400 hseg)"
MNT="$(ct_mnt hseg)"

grown() {
    ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    ct_growfs "$DEV" >/dev/null 2>&1 || { fail "setup: growfs failed"; ct_exit; }
    HEAD="$("$SEG_POKE" "$DEV" dump | grep -oP 'head=\K[0-9]+')"
    [ -n "$HEAD" ] || { fail "setup: the grow left no appended segment"; ct_exit; }
}

try() { # <label> <expect: refused|mounted>
    local mark rc=0
    blockdev --flushbufs "$DEV"
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
    [ "$rc" = 0 ] && umount "$MNT"
    if [ "$2" = refused ]; then
        [ "$rc" != 0 ] && grep -qE "BG table segment .*(fixed tables|overlaps Block Group)" <<<"$(dmesg_since "$mark")" &&
            pass "$1: the mount was refused" ||
            fail "$1: mount rc=$rc -- a misplaced BG table segment was accepted"
    else
        [ "$rc" = 0 ] && pass "$1: mounted" || fail "$1: a correctly placed segment was refused (rc=$rc)"
    fi
}

log "A: the segment on the inode table"
grown
ITS="$("$BG_POKE" "$DEV" 0 --dump | grep -oP 'inode_table_start=\K[0-9]+')"
"$SEG_POKE" "$DEV" copyto $((ITS + 900)) >/dev/null
"$SB_POKE" "$DEV" bg_table_next $((ITS + 900)) >/dev/null
try A refused

log "B: the segment inside Block Group 0"
grown
B0="$("$BG_POKE" "$DEV" 0 --dump)"
S0="$(grep -oP 'start_block=\K[0-9]+' <<<"$B0")"
R0="$(grep -oP 'off_data_region=\K[0-9]+' <<<"$B0")"
"$SEG_POKE" "$DEV" copyto $((S0 + R0 + 5000)) >/dev/null
"$SB_POKE" "$DEV" bg_table_next $((S0 + R0 + 5000)) >/dev/null
try B refused

log "C: control -- the segment where the grow put it"
grown
try C mounted
ct_exit
