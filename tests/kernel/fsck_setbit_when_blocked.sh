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
# DISCRIMINATION: CETRAFS_TEST_FSCK_SETBIT_GATED=1 (as before): c's block
# stays free.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PFPOKE="$(ct_helper pending_poke)"
PPOKE="$(ct_helper extent_phys_poke)"
BGPOKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt fsb)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <gated 0|1> -> RES
round() {
    local img dev a b c pa pc d0 ds bm off byte out
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
    off=$((bm * 4096 + (pc - ds) / 8))
    byte="$(dd if="$img" bs=1 skip="$off" count=1 status=none | od -An -tu1 | tr -d ' ')"
    printf "\\x$(printf %02x $((byte & ~(1 << ((pc - ds) % 8)))))" | dd of="$img" bs=1 seek="$off" conv=notrunc status=none
    blockdev --flushbufs "$dev"
    if [ "$2" = 1 ]; then
        out="$(CETRAFS_TEST_FSCK_SETBIT_GATED=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    else
        out="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    fi
    blockdev --flushbufs "$dev"
    byte="$(dd if="$img" bs=1 skip="$off" count=1 status=none | od -An -tu1 | tr -d ' ')"
    RES="overlap=$(grep -c 'cross-file overlap' <<<"$out" || true) blocked=$(grep -c 'repair is disabled' <<<"$out" || true)"
    RES="$RES unmarked=$(grep -c 'marked FREE' <<<"$out" || true) cbit=$(((byte >> ((pc - ds) % 8)) & 1))"
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
ct_exit
