#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r marks a named block in use even when another fault blocks repair
#
# Setting the bit of a block a live extent names can only ever leak it,
# never share it. fsck -r still made that repair wait for every other
# fault, so a double allocation -- which blocks repair, and whose
# aftermath is exactly blocks named but marked free -- left them free for
# the allocator to hand out once more (audit 2026-11-15 BM-67).
#
# Planted: file b's extent redirected onto file a's block (two inodes on
# one block: repair is blocked), and file c's block marked free in the
# bitmap while c still names it:
#   1. fsck -r reports the overlap and that repair is disabled;
#   2. c's block is marked in use afterwards.
#
# Z. the same, with Block Group 0's count and Zone Group 0's total both
#    overstated: the blocked run lowers the group's count, and must lower
#    the total with it -- left alone it stood above the groups just
#    lowered under it (audit 2026-11-15 F-34).
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_SETBIT_GATED=1 (as before): c's block
# stays free. CETRAFS_TEST_FSCK_ZG_LOWER_GATED=1 (as before F-34): Z's
# total stays above its groups.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PFPOKE="$(ct_helper pending_poke)"
PPOKE="$(ct_helper extent_phys_poke)"
BGPOKE="$(ct_helper bg_poke)"
BMP="$(ct_helper bmap_poke)"
MNT="$(ct_mnt fsb)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <gated 0|1> [Z <zg gated 0|1>] -> RES
round() {
    local img dev a b c pa pc d0 ds bm out out2 fr
    img="$(ct_image 560 "fsb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    for f in a b c; do head -c 4096 /dev/urandom >"$MNT/$f"; done
    sync
    a="$(stat -c %i "$MNT/a")"
    b="$(stat -c %i "$MNT/b")"
    c="$(stat -c %i "$MNT/c")"
    ct_umount "$MNT"
    pa="$("$PFPOKE" "$img" extent "$a" | awk '{ print $1 }')"
    pc="$("$PFPOKE" "$img" extent "$c" | awk '{ print $1 }')"
    [ -n "$pa" ] && [ -n "$pc" ] || { fail "setup: no extents for a/c"; ct_exit; }
    "$PPOKE" "$img" "$b" "$pa" >/dev/null || { fail "setup: could not redirect b onto a's block"; ct_exit; }
    d0="$("$BGPOKE" "$dev" 0 --dump)"
    ds=$(( $(grep -oP 'start_block=\K[0-9]+' <<<"$d0") + $(grep -oP 'off_data_region=\K[0-9]+' <<<"$d0") ))
    bm=$(( $(grep -oP 'start_block=\K[0-9]+' <<<"$d0") + $(grep -oP 'off_data_bmap=\K[0-9]+' <<<"$d0") ))
    "$BMP" "$img" "$bm" "$((pc - ds))" 0
    if [ "${3:-}" = Z ]; then
        fr="$(grep -oP 'free_data_blocks=\K[0-9]+' <<<"$d0")"
        "$BGPOKE" "$img" 0 $((fr + 50)) sync-zg >/dev/null || { fail "setup: bg_poke sync-zg"; ct_exit; }
    fi
    blockdev --flushbufs "$dev"
    if [ "${3:-}" = Z ] && [ "$4" = 1 ]; then
        out="$(CETRAFS_TEST_FSCK_ZG_LOWER_GATED=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    elif [ "$2" = 1 ]; then
        out="$(CETRAFS_TEST_FSCK_SETBIT_GATED=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    else
        out="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    fi
    blockdev --flushbufs "$dev"
    cbit="$("$BMP" "$img" "$bm" "$((pc - ds))")"
    RES="overlap=$(grep -c 'cross-file overlap' <<<"$out" || true) blocked=$(grep -c 'repair is disabled' <<<"$out" || true)"
    RES="$RES unmarked=$(grep -c 'marked FREE' <<<"$out" || true) cbit=$cbit"
    out2="$("$ROOT/userspace/fsck.cetra" "$dev" 2>&1 || true)"
    RES="$RES zgbefore=$(grep -c 'ZG0 aggregate free_data_blocks' <<<"$out" || true)"
    RES="$RES zgafter=$(grep -c 'ZG0 aggregate free_data_blocks' <<<"$out2" || true)"
}

round c 1
C="$RES"
log "control (gated): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get overlap "$R")" -ge 1 ] && [ "$(get blocked "$R")" -ge 1 ] && [ "$(get unmarked "$R")" -ge 1 ] &&
    pass "1: fsck -r saw the overlap, disabled repair, and found c's block marked free" ||
    { fail "setup: $R"; ct_exit; }
[ "$(get cbit "$R")" = 1 ] && pass "2: c's block is marked in use despite the blocked repair" || fail "2: $R"
[ "$(get cbit "$C")" = 0 ] && pass "control: gated, c's block was left free to be handed out again" ||
    fail "control: c's block was marked without the change -- the suite does not reach the gate: $C"

round z 0 Z 0
Z="$RES"
log "Z fixed: $Z"
round zc 0 Z 1
ZC="$RES"
log "Z control (totals left alone): $ZC"
[ "$(get blocked "$Z")" -ge 1 ] && [ "$(get zgbefore "$Z")" -ge 1 ] ||
    { fail "setup: Z had no blocked repair or no overstated total: $Z"; ct_exit; }
[ "$(get zgafter "$Z")" = 0 ] && pass "Z: the blocked run lowered the Zone Group total with its group" ||
    fail "Z: the total still disagrees with its groups after the run: $Z"
[ "$(get zgafter "$ZC")" -ge 1 ] && pass "Z control: as before, the total was left above its groups" ||
    fail "Z control: the total agreed without the change -- the suite does not reach it: $ZC"
ct_exit
