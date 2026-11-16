#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace operation does not wait for a peer's replay under the VFS's locks
#
# Breaking a dead holder's namespace lock replays its journal first, and
# a replay waits for any other node already replaying it -- a wait with
# no bound of its own. A create or unlink did that under the VFS's own
# directory lock, so every task queued on the directory, an ls or a
# lookup, waited with it (audit 2026-11-15 BM-27). Such an operation now
# does not wait for the claim: it restarts, outside the VFS's locks, and
# finds the journal replayed.
#
# Row 1, dead, holds d's namespace lock and has a dirty journal, which
# row 2 is replaying (a live replay claim, forced live). A create in d
# waits; meanwhile an ls of d:
#   fixed:   returns at once;
#   control: nslock_replay_waits_in_vfs=1 -- it waits behind the create.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
JPOKE="$(ct_helper journal_poke)"
IMG="$(ct_image 560 nsrcl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nsrcl)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_replay_sweep_off 1
ct_param_set nslock_replay_waits_in_vfs 0
ct_param_set force_live_replay_claim 0

ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
echo hb_interval_secs=5 >"$CTL"
echo stale_secs=15 >"$CTL"
mkdir "$MNT/d1" "$MNT/d2"
: >"$MNT/d1/a"
: >"$MNT/d2/a"
sync

# <tag> <waits 0|1> <dir> -> RES
round() {
    local d="$MNT/$3" pid t0 t1 ls
    poke_dead_peer "$DEV" 1 aa
    "$NPOKE" "$DEV" 1 --stale 15 >/dev/null
    poke_dead_peer "$DEV" 2 bb
    "$LPOKE" "$DEV" "$(stat -c %i "$d")" --ns 1 >/dev/null
    "$JPOKE" "$DEV" 1 --claim 2 >/dev/null # dirty, and row 2 replaying it
    wait_for 60 "grep -q '^node 1: .*stale=yes' '$(ct_procdir "$DEV")/cluster'" ||
        { fail "setup: row 1 never went stale"; ct_exit; }
    echo "$2" >/sys/module/cetrafs/parameters/nslock_replay_waits_in_vfs
    echo 1 >/sys/module/cetrafs/parameters/force_live_replay_claim
    touch "$d/new" 2>/dev/null &
    pid=$!
    sleep 3 # the create is at the claim
    t0="$(date +%s.%N)"
    ls="$(timeout 20 ls "$d" >/dev/null 2>&1 && echo ok || echo timeout)"
    t1="$(date +%s.%N)"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo 0 >/sys/module/cetrafs/parameters/force_live_replay_claim
    echo 0 >/sys/module/cetrafs/parameters/nslock_replay_waits_in_vfs
    "$JPOKE" "$DEV" 1 --claim release >/dev/null
    RES="ls=$ls secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')"
}

round f 0 d1
F="$RES"
log "fixed: $F"
round c 1 d2
C="$RES"
log "control (the claim waited for under the VFS lock): $C"
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
[ "$(field ls "$F")" = ok ] && awk -v s="$(field secs "$F")" 'BEGIN { exit !(s < 2) }' &&
    pass "fixed: ls of the directory returned at once while the create waited ($F)" || fail "fixed: $F"
awk -v s="$(field secs "$C")" 'BEGIN { exit !(s >= 4) }' &&
    pass "control: as before, ls waited behind the create's replay wait ($C)" ||
    fail "control: ls did not wait -- the suite does not reach the claim: $C"
ct_umount "$MNT"
ct_exit
