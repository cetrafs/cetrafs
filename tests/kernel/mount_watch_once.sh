#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount watches a dead registry row once, not once per question
# ct-timeout: 480
#
# A row that stopped beating is proven dead by watching it stand still
# for a whole window. A mount asks three questions that can each need
# that: the file-lock mode walk before registration, the re-attach of
# this machine's own row left uncleanly, and the mode re-check after
# registration -- and each watched again, about six minutes at the
# default window (audit 2026-11-15 BM-22). A row seen still for a window
# that still reads at that mark has been silent longer than a window, so
# the mount now remembers the verdict; and the mode walk watches its own
# unclean row alongside the peers, so the re-attach has its verdict too.
#
# Row 0 is this node's, left uncleanly; row 1 a dead peer advertising
# file_lock=off, which a default mount's two mode walks depend on. The
# window is 20 s:
#   1. one watch of 20 s, and the re-attach takes the walk's verdict;
#   2. the mount still leads with file_lock=on (the dead row imposes
#      nothing) and the re-attach still sweeps.
#
# A writable mount's election now fences a row it watched dead (N-58), so
# the later questions find it fenced and watch nothing either way. The
# mechanism is therefore also measured with that fence off
# (election_silent_unfenced=1), where the remembered verdict alone stands
# between the mount and three watches.
#
# DISCRIMINATION: row_silent_forget=1 (fence off) -- three watches, about
# a minute.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_mode_own # the mode walk is what it measures
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt watchonce)"
ct_track mnt "$MNT"
for k in mount_assume_caw election_silent_unfenced; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
# As on a CAW device: on a loop device the no-CAW gate watches and fences
# the peer row before either mode walk could see it.
ct_param_set mount_assume_caw 1
ct_param_set row_silent_forget 0
ct_param_set election_silent_unfenced 0
ct_param_set stale_secs 20
ct_param_set hb_interval_secs 2
fresh() { DEV="$(ct_loop "$(ct_image 560 "watchonce$1")")"; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <forget 0|1> <unfenced 0|1> -> RES
round() {
    local mark t0 t1 me log
    fresh "$1"
    ct_mkfs_small "$DEV" >/dev/null
    mount -t cetrafs "$DEV" "$MNT"
    me="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    umount "$MNT"
    "$NPOKE" "$DEV" "$me" --depart 0 >/dev/null # left uncleanly
    poke_dead_peer "$DEV" 1 aa
    "$NPOKE" "$DEV" 1 --stale 20 >/dev/null
    "$NPOKE" "$DEV" 1 --mode 2 >/dev/null
    blockdev --flushbufs "$DEV"
    echo "$2" >/sys/module/cetrafs/parameters/row_silent_forget
    echo "$3" >/sys/module/cetrafs/parameters/election_silent_unfenced
    mark="$(dmesg_mark)"
    t0="$(date +%s)"
    mount -t cetrafs "$DEV" "$MNT"
    t1="$(date +%s)"
    echo 0 >/sys/module/cetrafs/parameters/row_silent_forget
    echo 0 >/sys/module/cetrafs/parameters/election_silent_unfenced
    log="$(dmesg_since "$mark")"
    RES="secs=$((t1 - t0)) walks=$(grep -c 'watching 1 registry row' <<<"$log" || true)"
    RES="$RES reattach_watch=$(grep -c "watching it [0-9]*s to be sure" <<<"$log" || true)"
    RES="$RES taken=$(grep -c 'already watched it stand still' <<<"$log" || true)"
    RES="$RES lock=$(sed -n 's/^file_lock: //p' "$(ct_procdir "$DEV")/info")"
    grep -q "re-attached row $me" <<<"$log" && RES="$RES reattached=yes" || RES="$RES reattached=no"
    umount "$MNT"
}

round f 0 0
F="$RES"
log "fixed: $F"
round u 0 1
U="$RES"
log "fixed, election fence off: $U"
round c 1 1
C="$RES"
log "control (every watch watches again, election fence off): $C"
for R in "$F" "$U"; do
    [ "$(field walks "$R")" = 1 ] && [ "$(field reattach_watch "$R")" = 0 ] && [ "$(field taken "$R")" = 1 ] &&
        [ "$(field secs "$R")" -lt 40 ] &&
        pass "1: one watch, and the re-attach took its verdict ($R)" || fail "1: $R"
    [ "$(field lock "$R")" = on ] && [ "$(field reattached "$R")" = yes ] &&
        pass "2: the dead row imposed nothing, and the row was re-attached ($R)" || fail "2: $R"
done
[ "$(field walks "$C")" = 2 ] && [ "$(field reattach_watch "$C")" = 1 ] && [ "$(field secs "$C")" -ge 55 ] &&
    pass "control: as before, three watches of the same rows ($C)" ||
    fail "control: $C -- the suite does not reach the three watches"
ct_exit
