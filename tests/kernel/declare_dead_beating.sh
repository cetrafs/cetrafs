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
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
IMG="$(ct_image 560 declbeat)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt declbeat)"
ct_track mnt "$MNT"
ct_param_set declare_dead_unguarded 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <unguarded 0|1> -> RES
round() {
    local ctl mark rc=0 e0 r
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
