#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs writes a grown inode segment's records dead, never zeros
#
# mkfs writes a DEAD record into every inode slot, never zeros: an
# all-zero record under a set bit cannot be told from a live record
# read back as zeros, so no walk that frees may judge it, and a create
# that stopped between its bit and its record stalled every node's
# scrub until an offline fsck -r (audit 2026-11-15 F-12). growfs zeroed
# the records of the segment it appends, which put the same mode back
# on every grown volume (audit 2026-11-22 N-5). It now stamps each one
# dead with its own number.
#
# Offline grow of a 700 MiB, 1024-inode volume to 1400 MiB and 4096
# inodes, then:
#   1. the first, a middle and the last record of the grown segment carry
#      their own inode number (a dead record; zeros carry 0), and fsck is
#      clean;
#   2. the bit of the first grown number set, as a create that stopped
#      after its bit leaves it: fsck sees an orphan with a record, not a
#      "record never written".
#
# DISCRIMINATION: the control, in-suite --
# CETRAFS_GROWFS_TEST_ZERO_INODE_RECORDS=1, the zeros: the records carry
# 0 and fsck reports the record as never written.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
SBPOKE="$(ct_helper sb_poke)"
BMAP="$(ct_helper bmap_poke)"
GROWFS="$ROOT/userspace/growfs.cetra"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1600 gidr)"
DEV="$(ct_loop "$IMG")"

ino_at() { # <lba>: the record's inode number (its first 8 bytes, LE)
    dd if="$DEV" bs=4096 skip="$1" count=1 status=none |
        od -An -tu8 -N8 | tr -d ' '
}

# round <zero 0|1> -> "first=<n> mid=<n> last=<n> clean=<0|1> never=<0|1> orphan=<0|1>"
round() {
    local seg first count n nb tbl clean=0 never=0 orphan=0 out
    ct_mkfs "$DEV" -s 700M -N 1024 -f >/dev/null
    if [ "$1" = 1 ]; then
        CETRAFS_GROWFS_TEST_ZERO_INODE_RECORDS=1 "$GROWFS" "$DEV" -s 1400M -N 4096 >/dev/null 2>&1
    else
        "$GROWFS" "$DEV" -s 1400M -N 4096 >/dev/null 2>&1
    fi
    blockdev --flushbufs "$DEV"
    out="$("$SBPOKE" "$DEV")"
    seg="$(sed -n 's/^inode_seg_next=//p' <<<"$out")"
    first="$(sed -n 's/^inode_first_count=//p' <<<"$out")"
    count="$(sed -n 's/^inodes_count=//p' <<<"$out")"
    n=$((count - first))
    [ "${seg:-0}" != 0 ] && [ "$n" -gt 0 ] || { echo "setup: no grown inode segment (seg=$seg n=$n)"; return; }
    nb=$(((n + 31743) / 31744))
    tbl=$((seg + 1 + nb))
    "$FSCK" "$DEV" >/dev/null 2>&1 && clean=1
    "$BMAP" "$DEV" $((seg + 1)) 0 1 >/dev/null
    blockdev --flushbufs "$DEV"
    out="$("$FSCK" "$DEV" 2>&1 || true)"
    grep -q "inode $((first + 1)) is marked in use but its record was never written" <<<"$out" && never=1
    grep -q "inode $((first + 1)) is allocated but has nlink=0 (orphan)" <<<"$out" && orphan=1
    echo "want=$((first + 1)),$((first + 1 + n / 2)),$count first=$(ino_at "$tbl") mid=$(ino_at $((tbl + n / 2)))" \
        "last=$(ino_at $((tbl + n - 1))) clean=$clean never=$never orphan=$orphan"
}

get() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p"; }

R="$(round 1)"
log "control: $R"
[ "$(get first "$R")" = 0 ] && [ "$(get never "$R")" = 1 ] &&
    pass "control: with the zeros, the grown records carry no number and fsck finds one never written" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $R"

R="$(round 0)"
log "fixed: $R"
W="$(get want "$R")"
[ "$(get first "$R"),$(get mid "$R"),$(get last "$R")" = "$W" ] && [ "$(get clean "$R")" = 1 ] &&
    pass "the grown records are dead, each with its own number ($W), and fsck is clean" ||
    fail "grown records: $R"
[ "$(get never "$R")" = 0 ] && [ "$(get orphan "$R")" = 1 ] &&
    pass "a set bit over a grown slot is an orphan with a record, not a record never written" ||
    fail "a set bit over a grown slot: $R"
ct_exit
