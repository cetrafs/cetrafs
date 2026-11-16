#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace operation's recount and foreign-user settle run outside the VFS's locks
#
# Two waits still ran inside a namespace operation's set and the VFS's
# directory lock: the recount of a namespace lock taken over from a dead
# holder (a read of every dirent block), and the settle of a file's
# foreign users -- a dead holder's fence and journal replay, a peer's
# mover asked back (audit 2026-11-15 BM-27). Every task queued on the
# directory, an ls or a lookup, waited with them. Now the operation,
# having changed nothing, restarts the call and the work runs outside.
#
#   R. row 1, dead, holds d1's namespace lock; a create in d1 takes it
#      over, and its recount is held 5 s (nslock_recount_stall_ms);
#   S. row 2, dead, holds f's file lock; an unlink of d2/f fences it,
#      and the fence is held 5 s (fence_stall_ms).
# Meanwhile an ls of the directory: fixed, at once; and the operation
# still succeeds, restarted exactly once.
#
# DISCRIMINATION: nslock_settle_in_vfs=1 -- ls waits behind the work.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 nssettle)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nssettle)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_replay_sweep_off 1
ct_param_set nslock_settle_in_vfs 0
ct_param_set nslock_recount_stall_ms 0
ct_param_set fence_stall_ms 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 8 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
echo hb_interval_secs=5 >"$CTL"
echo stale_secs=15 >"$CTL"
for d in r1 r2 s1 s2; do mkdir "$MNT/$d"; : >"$MNT/$d/a"; done
for d in s1 s2; do echo x >"$MNT/$d/f"; done
sync

# <R|S> <in_vfs 0|1> <dir> <row> -> RES
round() {
    local d="$MNT/$3" row="$4" pid t0 t1 ls ok n0 rc=0
    poke_dead_peer "$DEV" "$row" "$(printf '%02x' $((row + 160)))"
    "$NPOKE" "$DEV" "$row" --stale 15 >/dev/null
    if [ "$1" = R ]; then
        "$LPOKE" "$DEV" "$(stat -c %i "$d")" --ns "$row" >/dev/null
    else
        "$LPOKE" "$DEV" "$(stat -c %i "$d/f")" "$row" 1 >/dev/null
    fi
    wait_for 60 "grep -q '^node $row: .*stale=yes' '$(ct_procdir "$DEV")/cluster'" ||
        { fail "setup: row $row never went stale"; ct_exit; }
    echo "$2" >/sys/module/cetrafs/parameters/nslock_settle_in_vfs
    if [ "$1" = R ]; then
        echo 5000 >/sys/module/cetrafs/parameters/nslock_recount_stall_ms
    else
        echo 5000 >/sys/module/cetrafs/parameters/fence_stall_ms
    fi
    n0="$(info nslock_settle_deferred)"
    if [ "$1" = R ]; then touch "$d/new" & else rm "$d/f" & fi
    pid=$!
    sleep 1 # the operation is in its slow part
    t0="$(date +%s.%N)"
    ls="$(timeout 20 ls "$d" >/dev/null 2>&1 && echo ok || echo timeout)"
    t1="$(date +%s.%N)"
    wait "$pid" || rc=$?
    echo 0 >/sys/module/cetrafs/parameters/nslock_recount_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/fence_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/nslock_settle_in_vfs
    if [ "$1" = R ]; then [ -e "$d/new" ] && ok=yes || ok=no; else [ -e "$d/f" ] && ok=no || ok=yes; fi
    RES="ls=$ls secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') done=$ok rc=$rc"
    RES="$RES deferred=$(($(info nslock_settle_deferred) - n0))"
}

round R 0 r1 1
R="$RES"
log "R fixed: $R"
round R 1 r2 2
RC="$RES"
log "R control (recount under the VFS lock): $RC"
round S 0 s1 3
S="$RES"
log "S fixed: $S"
round S 1 s2 4
SC="$RES"
log "S control (settle under the VFS lock): $SC"

for x in "R:$R" "S:$S"; do
    t="${x%%:*}" v="${x#*:}"
    [ "$(field ls "$v")" = ok ] && awk -v s="$(field secs "$v")" 'BEGIN { exit !(s < 2) }' &&
        [ "$(field done "$v")" = yes ] && [ "$(field rc "$v")" = 0 ] && [ "$(field deferred "$v")" = 1 ] &&
        pass "$t: ls returned at once while the work ran outside, and the operation succeeded ($v)" ||
        fail "$t: $v"
done
for x in "R:$RC" "S:$SC"; do
    t="${x%%:*}" v="${x#*:}"
    awk -v s="$(field secs "$v")" 'BEGIN { exit !(s >= 3) }' && [ "$(field done "$v")" = yes ] &&
        pass "$t control: as before, ls waited behind the work under the VFS lock ($v)" ||
        fail "$t control: ls did not wait -- the suite does not reach the work: $v"
done
ct_umount "$MNT"
ct_exit
