#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a procfs sweep stops on a kill and on unmount
#
# The info and cluster files read every Block Group, Zone Group or
# registry row in turn, each read uninterruptible. On a stalled device a
# reader hung for all of them, a kill could not end it, and unmount's
# proc_remove() waited for it (audit 2026-11-15 BM-52). A sweep now stops
# at its next step on a fatal signal or once an unmount has begun.
#
# Each sweep step sleeps 300 ms (proc_sweep_step_ms), standing in for a
# stalled read. The cluster file reads every registry slot, printed or
# not; the control proves a read outlasts the kill and the unmount.
#   K. a reader killed mid-sweep exits at once;
#   U. an unmount with a reader mid-sweep does not wait for it.
#
# DISCRIMINATION: proc_sweep_unstoppable=1 -- both wait out the sweep.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IMG="$(ct_image 560 procstop)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt procstop)"
ct_track mnt "$MNT"
ct_param_set proc_sweep_step_ms 0
ct_param_set proc_sweep_unstoppable 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
ms() { echo $((($(date +%s%N) - $1) / 1000000)); }

# <tag> <unstoppable 0|1> -> RES
round() {
    local cl pid t0 kms ums
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    cl="$(ct_procdir "$DEV")/cluster"
    echo "$2" >/sys/module/cetrafs/parameters/proc_sweep_unstoppable
    echo 300 >/sys/module/cetrafs/parameters/proc_sweep_step_ms
    cat "$cl" >/dev/null &
    pid=$!
    sleep 2
    t0="$(date +%s%N)"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kms="$(ms "$t0")"
    cat "$cl" >/dev/null &
    pid=$!
    sleep 2
    t0="$(date +%s%N)"
    umount "$MNT"
    ums="$(ms "$t0")"
    wait "$pid" 2>/dev/null || true
    echo 0 >/sys/module/cetrafs/parameters/proc_sweep_step_ms
    echo 0 >/sys/module/cetrafs/parameters/proc_sweep_unstoppable
    RES="kill_ms=$kms umount_ms=$ums"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (sweeps unstoppable): $C"
[ "$(field kill_ms "$F")" -lt 1500 ] && pass "K: a reader killed mid-sweep exited at once ($F)" || fail "K: $F"
[ "$(field umount_ms "$F")" -lt 3000 ] && pass "U: the unmount did not wait for the sweep ($F)" || fail "U: $F"
[ "$(field kill_ms "$C")" -ge 5000 ] && [ "$(field umount_ms "$C")" -ge 5000 ] &&
    pass "control: as before, both waited out the sweep ($C)" ||
    fail "control: no wait -- the suite does not reach the sweep: $C"
ct_exit
