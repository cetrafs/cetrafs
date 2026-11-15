#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a survivor whose replay of a dead node's journal is refused by the device stays up
#
# A replay redoes each surviving entry with a synchronous write, and any
# failed metadata write stopped the mount. A block the array refuses for
# every node -- a snapshot's copy-on-write with the pool full, a write
# protect -- therefore stopped each survivor that came to replay the
# dead node's area, one stale window after the other, and boot-looped a
# node mounting under errors=panic; the area was never replayed (audit
# 2026-11-15 B-25, B-34). A DEFINITE refusal (BLK_STS_NOSPC,
# BLK_STS_TARGET) now fails just that replay: the entry is kept, the area
# stays DIRTY, the claim is released, and the replayer lives to try again.
#
# Played on one node: node 1 is a dead peer with a journal entry putting
# an older image of a directory block back; this node's heartbeat sweep
# replays it, every write of the target block answered "no space"
# (meta_write_nospc_block) until the suite lifts it:
#   1. the mount is not stopped; node 1's area is still DIRTY and nobody
#      holds its replay claim;
#   2. a later sweep, the refusal gone, redoes it: the area is CLEAN and
#      the directory reads as the entry says.
#
# DISCRIMINATION: replay_refusal_stops=1 (the refusal stops, as before):
# 1 fails -- the mount stops.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in meta_write_nospc_block replay_refusal_stops; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jrr)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set meta_write_nospc_block 0
ct_param_set replay_refusal_stops 0
compress_timing
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <stops 0|1> -> RES
round() {
    local img dev blk tgt mark d1 d2 a0 ls
    img="$(ct_image 560 "jrr$1")"
    dev="$(ct_loop "$img")"
    blk="$(ct_tmp "jrr-a$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mark="$(dmesg_mark)"
    touch "$MNT/alpha"
    tgt="$(dmesg_since "$mark" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
    ct_umount "$MNT"
    [ -n "$tgt" ] || { fail "setup: no journal entry logged for a create"; ct_exit; }
    dd if="$dev" of="$blk" bs=4096 skip="$tgt" count=1 status=none
    ct_mount "$dev" "$MNT"
    touch "$MNT/beta"
    ct_umount "$MNT"
    poke_dead_peer "$dev" 1 aa
    "$JPOKE" "$dev" 1 0 "$tgt" "$blk" --guard-current >/dev/null
    grep -q "^state=1 " <<<"$("$JPOKE" "$dev" 1 --dump)" || { fail "setup: the planted entry did not dirty node 1's area"; ct_exit; }
    echo "$2" >$P/replay_refusal_stops
    echo "$tgt" >$P/meta_write_nospc_block
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    wait_for 40 "dmesg_since '$mark' | grep -q 'failed to redo target'" || true
    sleep 1
    d1="$("$JPOKE" "$dev" 1 --dump | head -1)"
    RES="refused=$(dmesg_since "$mark" | grep -c 'failed to redo target' || true)"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true) after1=[${d1// /_}]"
    echo 0 >$P/meta_write_nospc_block
    a0="$(info journal_replay_applied)"
    if [ "$(get stopped "$RES")" = 0 ]; then
        wait_for 40 "[ \"\$(awk '\$1 == \"journal_replay_applied:\" { print \$2 }' '$PROC/info')\" -gt '$a0' ]" || true
    fi
    ls="$( (ls "$MNT" 2>/dev/null || true) | sort | tr '\n' ',')"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/replay_refusal_stops
    d2="$("$JPOKE" "$dev" 1 --dump | head -1)"
    RES="$RES after2=[${d2// /_}] ls=$ls"
}

round c 1
C="$RES"
log "control (a refusal stops): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get refused "$R")" -ge 1 ] || { fail "setup: the replay's redo was never refused ($R)"; ct_exit; }
[ "$(get stopped "$R")" = 0 ] && grep -q 'state=1_' <<<"$(get after1 "$R")" &&
    grep -q '_claimed=0_' <<<"$(get after1 "$R")" &&
    pass "1: the refused redo left the mount up, node 1's area DIRTY and its claim released" || fail "1: $R"
grep -q 'state=0_' <<<"$(get after2 "$R")_" && [ "$(get ls "$R")" = "alpha," ] &&
    pass "2: a later sweep redid it: the area is CLEAN and the directory reads as the entry says" || fail "2: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with the refusal stopping, the replaying node stopped" ||
    fail "control: the refusal did not stop the replayer ($C) -- the suite does not reach the redo"
ct_exit
