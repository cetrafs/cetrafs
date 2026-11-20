#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a nofilelock open past a live peer's settled journal does not wait for its beat
#
# A nofilelock open of a file a not-yet-stale peer has open, with that
# peer's journal dirty, used to watch the peer's row for its NEXT beat
# (M-20: never open past a dead node's unreplayed journal). The stale
# check right before it had just sampled the row, so every such open
# waited out most of a heartbeat: 8-15 s per open of a live-migration
# source's image, and several of them per qemu-img, on a real cluster.
# A live writer's journal is always dirty -- held-back batch entries
# stay live until the next batch retires them -- but every entry in it
# has landed. The open now asks the journal: when a replay would redo
# nothing, there is nothing to run past and it goes on at once; only an
# entry replay would still redo sends it to the wait.
#
# Node 1 has "img" open and a dirty journal with one entry for the
# root's dirent block (s0 -> s1). It beats every $PERIOD s, as a live
# node does (slower than ct_beat_row's 1 s, so a wait is measurable):
#   F. the entry has landed (target at s1): three opens, each fast, all
#      by the journal (open_peer_settled), none waiting;
#   P. the entry has not landed (target at s0): the open still waits for
#      the beat (open_peer_waits), then goes on -- and the journal is
#      left to its live owner (target still s0);
#   L. the entry has landed and node 1 is SILENT: nothing to run past,
#      so the open goes on at once (a pending entry there is refused
#      EAGAIN: nofilelock_open_silent_peer.sh).
#
# The wait P falls back to judged a beat against the shared peer watch's
# last sample, which this node's heartbeat tick takes too: a beat the
# tick saw first was lost to the wait, which then also never timed out,
# and slipped by whole beats -- 40 s here, 14 s and 31 s on a cluster.
# It now judges against its own first sample: P waits one beat at most.
#
# DISCRIMINATION: open_journal_peek_off=1 (as before) -- F's opens wait
# for node 1's beat and take seconds each; peer_beating_shared_watch=1
# (as before) -- Q, P's setup, waits past a beat.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt nopf)"
ct_track mnt "$MNT"
PERIOD=5   # node 1's beat
FAST_MS=800
JDIRTY=1 # CETRAFS_NODE_JOURNAL_DIRTY
SLOW_MS=2000
ct_param_set open_silent_peer_ok 0
ct_param_set open_journal_peek_off 0
ct_param_set peer_beating_shared_watch 0
ct_param_set hb_replay_sweep_off 0
ct_param_set peer_beating_wait_secs 10
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
rootis() {
    if cmp -s <(dd if="$1" bs=4096 skip="$2" count=1 iflag=direct status=none) "$3/s1"; then echo s1
    elif cmp -s <(dd if="$1" bs=4096 skip="$2" count=1 iflag=direct status=none) "$3/s0"; then echo s0
    else echo other; fi
}
counter() { sed -n "s/^$2: //p" "$(ct_procdir "$1")/info"; }
# open+read+close of $1 -> "<ms>:<ok|eagain|err>"
timed_open() {
    local t0 t1 r
    t0="$(date +%s%N)"
    if cat "$1" >/dev/null 2>"$2"; then r=ok
    elif grep -q 'temporarily unavailable' "$2"; then r=eagain
    else r=err; fi
    t1="$(date +%s%N)"
    echo "$(((t1 - t0) / 1000000)):$r"
}
BEATER=""
slow_beat() { # <dev>: beat now, then every $PERIOD s
    "$NPOKE" "$1" 1 --beat >/dev/null
    (while sleep "$PERIOD"; do "$NPOKE" "$1" 1 --beat >/dev/null 2>&1; done) &
    BEATER=$!
    ct_track cmd "kill $BEATER 2>/dev/null; true"
}
stop_beat() { [ -n "$BEATER" ] && { kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true; }; BEATER=""; }

# <tag> <landed|pending> <beating|silent> <peek_off 0|1> [shared_watch 0|1] -> RES
round() {
    local img dev dir mark t ino o1 o2 o3 r s0 w0 st
    img="$(ct_image 560 "nopf$1")"
    dev="$(ct_loop "$img")"
    dir="$(ct_tmp "nopf-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    echo data >"$MNT/img"
    ino="$(stat -c %i "$MNT/img")"
    mark="$(dmesg_mark)"
    touch "$MNT/alpha"
    t="$(first_target "$mark")"
    umount "$MNT"
    [ -n "$t" ] || { fail "setup: no journal target logged for a create"; ct_exit; }
    blk "$dev" "$t" "$dir/s0"
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    touch "$MNT/beta"
    umount "$MNT"
    blk "$dev" "$t" "$dir/s1"
    ! cmp -s "$dir/s0" "$dir/s1" || { fail "setup: the create did not change the root's dirent block"; ct_exit; }
    poke_dead_peer "$dev" 1 aa
    "$NPOKE" "$dev" 1 --mode 2 >/dev/null
    if [ "$2" = landed ]; then
        # the device already holds s1: an entry s0 -> s1 that landed
        JOURNAL_POKE_TXN=1 JOURNAL_POKE_PREV_FROM="$dir/s0" "$JPOKE" "$dev" 1 0 "$t" "$dir/s1" >/dev/null
    else
        put "$dev" "$t" "$dir/s0"
        JOURNAL_POKE_TXN=1 "$JPOKE" "$dev" 1 0 "$t" "$dir/s1" --guard-current >/dev/null
    fi
    "$LPOKE" "$dev" "$ino" --reader 1 >/dev/null
    st="$("$JPOKE" "$dev" 1 --dump | grep -o 'state=[0-9]*')"
    [ "$st" = "state=$JDIRTY" ] || { fail "setup: node 1's journal flag reads $st, not DIRTY"; ct_exit; }
    "$JPOKE" "$dev" 1 --live | grep -q "target $t" ||
        { fail "setup: node 1's journal holds no live entry for block $t"; ct_exit; }

    echo 1 >$P/hb_replay_sweep_off
    echo "$4" >$P/open_journal_peek_off
    echo "${5:-0}" >$P/peer_beating_shared_watch
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    # A live peer beating every $PERIOD s must not read as stale here.
    echo stale_secs=60 >"$(ct_procdir "$dev")/controls"
    if [ "$3" = beating ]; then
        slow_beat "$dev"
    else
        "$NPOKE" "$dev" 1 --beat >/dev/null # registered, never beats again
    fi
    sleep 1
    s0="$(counter "$dev" open_peer_settled)"
    w0="$(counter "$dev" open_peer_waits)"
    o1="$(timed_open "$MNT/img" "$dir/e1")"
    o2="$(timed_open "$MNT/img" "$dir/e2")"
    o3="$(timed_open "$MNT/img" "$dir/e3")"
    r="$(rootis "$dev" "$t" "$dir")"
    RES="o1=$o1 o2=$o2 o3=$o3 root=$r settled=$(($(counter "$dev" open_peer_settled) - s0)) waits=$(($(counter "$dev" open_peer_waits) - w0))"
    stop_beat
    echo 0 >$P/open_journal_peek_off
    echo 0 >$P/peer_beating_shared_watch
    echo 0 >$P/hb_replay_sweep_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}
ms() { cut -d: -f1 <<<"$1"; }
res() { cut -d: -f2 <<<"$1"; }
within_beat() { # <RES>: every open ok, none longer than one beat plus a margin
    local o
    for o in o1 o2 o3; do
        [ "$(res "$(get $o "$1")")" = ok ] && [ "$(ms "$(get $o "$1")")" -lt $((PERIOD * 1000 + 1500)) ] || return 1
    done
}
all_fast() { # <RES>
    local o
    for o in o1 o2 o3; do
        [ "$(res "$(get $o "$1")")" = ok ] && [ "$(ms "$(get $o "$1")")" -lt $FAST_MS ] || return 1
    done
}

round f landed beating 0
F="$RES"
log "F (landed, beating): $F"
round p pending beating 0
PR="$RES"
log "P (pending, beating): $PR"
round q pending beating 0 1
Q="$RES"
log "control Q (pending, beating, shared-watch beat judgement -- as before): $Q"
round l landed silent 0
L="$RES"
log "L (landed, silent): $L"
round c landed beating 1
C="$RES"
log "control (landed, beating, peek off -- as before): $C"

all_fast "$F" && [ "$(get settled "$F")" -ge 3 ] && [ "$(get waits "$F")" = 0 ] && [ "$(get root "$F")" = s1 ] &&
    pass "F: three opens past a live peer's settled journal, each under ${FAST_MS} ms, none waiting" ||
    fail "F: $F"
[ "$(res "$(get o1 "$PR")")" = ok ] && [ "$(ms "$(get o1 "$PR")")" -ge $SLOW_MS ] && [ "$(get waits "$PR")" -ge 1 ] &&
    [ "$(get root "$PR")" = s0 ] &&
    pass "P: an entry replay would redo still sends the open to the beat wait; journal left to its owner" ||
    fail "P: $PR"
within_beat "$PR" &&
    pass "P: each such open waited at most one of the peer's beats (${PERIOD} s)" ||
    fail "P: an open waited past the peer's next beat: $PR"
within_beat "$Q" &&
    fail "control Q: judged against the tick's samples the wait still ended within a beat -- the suite does not reach it: $Q" ||
    pass "control Q: judged against the tick's samples, a wait slipped past the peer's beat"
all_fast "$L" && [ "$(get root "$L")" = s1 ] &&
    pass "L: a silent node whose journal holds nothing to redo does not hold the open" ||
    fail "L: $L"
[ "$(res "$(get o1 "$C")")" = ok ] && [ "$(ms "$(get o1 "$C")")" -ge $SLOW_MS ] && [ "$(get waits "$C")" -ge 1 ] &&
    pass "control: without the journal check the open waited for the peer's beat ($(ms "$(get o1 "$C")") ms)" ||
    fail "control: the open did not wait without the change -- the suite does not reach it: $C"
ct_exit
