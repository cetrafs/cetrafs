#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a nofilelock open waits out a silent, not-yet-stale opener with a dirty journal
#
# 96a06f8 replays a dead opener's journal before a nofilelock open, but
# only once that node is stale. HA restarting the VM inside the stale
# window opened it past the unreplayed journal, and the heartbeat's
# redo a window later landed on the new writer's tree (audit 2026-11-15
# M-20 status, point 1). Such an opener is now watched: beating -- a
# live-migration source -- the open goes on; silent, it is refused
# EAGAIN until the node is stale, when the open replays it first.
#
# Node 1 has "img" open, a dirty journal (one entry for the root's
# dirent block, s0 -> s1), and the heartbeat's own replay is held off:
#   S. node 1 silent: an open inside the stale window is refused EAGAIN;
#      after the window the open replays it -- root at s1;
#   B. node 1 beating: the open goes on, and its journal is left alone.
#
# DISCRIMINATION: open_silent_peer_ok=1 (as before): S's first open
# succeeds with the root still at s0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt nosp)"
ct_track mnt "$MNT"
ct_param_set open_silent_peer_ok 0
ct_param_set hb_replay_sweep_off 0
ct_param_set peer_beating_wait_secs 3
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
first_target() {
    dmesg_mark >/dev/null
    dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1 || true
}
blk() { dd if="$1" of="$3" bs=4096 skip="$2" count=1 iflag=direct status=none; }
put() { dd if="$3" of="$1" bs=4096 seek="$2" count=1 oflag=direct conv=notrunc status=none; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }
rootis() {
    if cmp -s <(dd if="$1" bs=4096 skip="$2" count=1 iflag=direct status=none) "$3/s1"; then echo s1
    elif cmp -s <(dd if="$1" bs=4096 skip="$2" count=1 iflag=direct status=none) "$3/s0"; then echo s0
    else echo other; fi
}
tryopen() { cat "$1" >/dev/null 2>"$2" && echo ok || { grep -q 'temporarily unavailable' "$2" && echo eagain || echo err; }; }

# <tag> <silent|beating> <ok_knob 0|1> -> RES
round() {
    local img dev dir mark t ino o1 o2="-" r1 r2="-"
    img="$(ct_image 560 "nosp$1")"
    dev="$(ct_loop "$img")"
    dir="$(ct_tmp "nosp-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nfmount "$dev" "$MNT"
    echo data >"$MNT/img"
    ino="$(stat -c %i "$MNT/img")"
    mark="$(dmesg_mark)"
    touch "$MNT/alpha"
    t="$(first_target "$mark")"
    umount "$MNT"
    [ -n "$t" ] || { fail "setup: no journal target logged for a create"; ct_exit; }
    blk "$dev" "$t" "$dir/s0"
    nfmount "$dev" "$MNT"
    touch "$MNT/beta"
    umount "$MNT"
    blk "$dev" "$t" "$dir/s1"
    ! cmp -s "$dir/s0" "$dir/s1" || { fail "setup: the create did not change the root's dirent block"; ct_exit; }
    put "$dev" "$t" "$dir/s0"
    poke_dead_peer "$dev" 1 aa
    "$(ct_helper node_poke)" "$dev" 1 --mode 2 >/dev/null
    JOURNAL_POKE_TXN=1 "$JPOKE" "$dev" 1 0 "$t" "$dir/s1" --guard-current >/dev/null
    "$LPOKE" "$dev" "$ino" --reader 1 >/dev/null

    echo 1 >$P/hb_replay_sweep_off
    echo "$3" >$P/open_silent_peer_ok
    # The no-CAW mount gate refuses a live peer and watches a silent one
    # for a window, so node 1 starts beating only after the mount: its
    # moves restart this node's watch, and a silent node then stops
    # right before the open -- inside a fresh stale window.
    nfmount "$dev" "$MNT"
    ct_beat_row "$dev" 1
    sleep 3
    [ "$2" = silent ] && ct_unbeat
    o1="$(tryopen "$MNT/img" "$dir/e1")"
    r1="$(rootis "$dev" "$t" "$dir")"
    if [ "$2" = silent ] && [ "$3" = 0 ]; then
        wait_out_stale_window
        o2="$(tryopen "$MNT/img" "$dir/e2")"
        r2="$(rootis "$dev" "$t" "$dir")"
    fi
    ct_unbeat
    RES="open1=$o1 root1=$r1 open2=$o2 root2=$r2"
    echo 0 >$P/open_silent_peer_ok
    echo 0 >$P/hb_replay_sweep_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round s silent 0
S="$RES"
log "S (silent): $S"
round b beating 0
B="$RES"
log "B (beating): $B"
round c silent 1
C="$RES"
log "control (silent, as before): $C"
[ "$(get open1 "$S")" = eagain ] && [ "$(get root1 "$S")" = s0 ] &&
    pass "S1: inside the stale window the open was refused EAGAIN" || fail "S1: $S"
[ "$(get open2 "$S")" = ok ] && [ "$(get root2 "$S")" = s1 ] &&
    pass "S2: once stale, the open replayed the journal first -- root at s1" || fail "S2: $S"
[ "$(get open1 "$B")" = ok ] && [ "$(get root1 "$B")" = s0 ] &&
    pass "B: a beating opener lets the open through, its journal left to it" || fail "B: $B"
[ "$(get open1 "$C")" = ok ] && [ "$(get root1 "$C")" = s0 ] &&
    pass "control: as before, the open ran past the silent node's journal" ||
    fail "control: the open did not go past it without the change -- the suite does not reach it: $C"
ct_exit
