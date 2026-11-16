#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# controls dead= refuses a row that is still beating
#
# A declare-dead made every peer replay and take over from the row at
# once, on the agent's word alone. An agent that names the wrong row, or
# declares before its power-off has taken effect, got a VM restarted
# elsewhere while the declared node, which only notices at its next
# fence check, went on writing the image (audit 2026-11-15 F-38). The
# row must now be seen to stand still, and the fence is bound to the
# mark that did.
#
# Row 1 (incarnation 7) keeps beating while dead=1:7 is written:
#   1. the declaration is refused (EBUSY), saying why;
#   2. the row is untouched: departure 0, fence_epoch as before.
# (A silent row is still declared: declare_dead.sh.)
#
# DISCRIMINATION: declare_dead_unguarded=1 -- the beating row is
# declared dead.
#
# And the silence it needs is the row's whole lease, three of its beats,
# not one beat plus a margin (a node 20 s silent was declared while its
# 45 s lease still ran):
#   L. row 1 advertises a 4 s beat, beats, goes quiet for 12 s, beats
#      again: the declaration made at the quiet start is refused.
# DISCRIMINATION: declare_silence_one_beat=1 -- it is accepted at 9 s.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
# A device per round: a row left registered would make the next mkfs on
# the same device watch it out first.
fresh() { DEV="$(ct_loop "$(ct_image 560 "declbeat$1")")"; }
MNT="$(ct_mnt declbeat)"
ct_track mnt "$MNT"
ct_param_set declare_dead_unguarded 0
ct_param_set declare_silence_one_beat 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <unguarded 0|1> -> RES
round() {
    local ctl mark rc=0 e0 r
    fresh "$1"
    ct_mkfs "$DEV" -z 1 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ctl="$(ct_procdir "$DEV")/controls"
    poke_dead_peer "$DEV" 1 aa
    "$NPOKE" "$DEV" 1 --inc 7 >/dev/null
    ct_beat_row "$DEV" 1
    sleep 3
    grep -q "^node 1: .*stale=no incarnation=7" "$(ct_procdir "$DEV")/cluster" ||
        { fail "setup: row 1 is not a live peer of incarnation 7"; ct_exit; }
    e0="$(field fence_epoch "$("$NPOKE" "$DEV" 1)")"
    echo "$2" >/sys/module/cetrafs/parameters/declare_dead_unguarded
    mark="$(dmesg_mark)"
    echo "dead=1:7" >"$ctl" 2>/dev/null || rc=1
    echo 0 >/sys/module/cetrafs/parameters/declare_dead_unguarded
    ct_unbeat
    r="$("$NPOKE" "$DEV" 1)"
    RES="accepted=$([ "$rc" = 0 ] && echo yes || echo no) departure=$(field departure "$r")"
    RES="$RES epoch_moved=$([ "$(field fence_epoch "$r")" = "$e0" ] && echo no || echo yes)"
    dmesg_since "$mark" | grep -q "row 1 is still beating" && RES="$RES said=yes" || RES="$RES said=no"
    ct_umount "$MNT"
}

# <tag> <one_beat 0|1> -> LRES
round_l() {
    local ctl mark rc=0 bpid
    fresh "$1"
    ct_mkfs "$DEV" -z 1 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ctl="$(ct_procdir "$DEV")/controls"
    "$NPOKE" "$DEV" 1 1 aa "$(date +%s)" 4 >/dev/null
    "$NPOKE" "$DEV" 1 --inc 7 >/dev/null
    "$NPOKE" "$DEV" 1 --beat >/dev/null
    blockdev --flushbufs "$DEV"
    echo "$2" >/sys/module/cetrafs/parameters/declare_silence_one_beat
    (sleep 12; "$NPOKE" "$DEV" 1 --beat >/dev/null) &
    bpid=$!
    mark="$(dmesg_mark)"
    echo "dead=1:7" >"$ctl" 2>/dev/null || rc=1
    wait "$bpid" || true
    echo 0 >/sys/module/cetrafs/parameters/declare_silence_one_beat
    LRES="accepted=$([ "$rc" = 0 ] && echo yes || echo no) departure=$(field departure "$("$NPOKE" "$DEV" 1)")"
    ct_umount "$MNT"
}

round_l l 0
L="$LRES"
log "L: $L"
round_l lc 1
LC="$LRES"
log "L control (one beat of silence): $LC"
[ "$(field accepted "$L")" = no ] && [ "$(field departure "$L")" = 0 ] &&
    pass "L: a row quiet for 12 s of a 4 s beat, then beating again, was not declared ($L)" || fail "L: $L"
[ "$(field accepted "$LC")" = yes ] &&
    pass "L control: as before, one beat of silence was enough to declare it ($LC)" ||
    fail "L control: $LC -- the suite does not reach the silence bound"

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (unguarded): $C"
[ "$(field accepted "$F")" = no ] && [ "$(field said "$F")" = yes ] &&
    pass "1: the declaration of a beating row was refused, saying why ($F)" || fail "1: $F"
[ "$(field departure "$F")" = 0 ] && [ "$(field epoch_moved "$F")" = no ] &&
    pass "2: the row was untouched ($F)" || fail "2: $F"
[ "$(field accepted "$C")" = yes ] && [ "$(field departure "$C")" != 0 ] &&
    pass "control: as before, the beating row was declared dead ($C)" ||
    fail "control: $C -- the suite does not reach the declaration"
ct_exit
