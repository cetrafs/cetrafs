#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stale-lock steal does not hold lock_mutex across the dead holder's fence and replay
#
# flock(LOCK_EX) and the default mount's resume take a dead holder's lock
# back by fencing the holder and replaying its journal -- which takes as
# long as that journal does (~210 s at worst) -- and did it holding the
# file's lock_mutex. Every local close, LOCK_UN and defrag end of the
# same file takes lock_mutex unkillably: one stale holder hung them all
# for the replay (audit 2026-11-22 N-21, C-1). The open path already
# drops the mutex for that; the steal now does too, taking it back
# killably and re-deciding from a fresh read.
#
# Staged on a nofilelock mount, as lock_mutex_killable.sh: row 1 holds
# the file's lock and is stale; A and B have the file open; A's flock
# reclaims the lock and is held 8 s between the fence and the replay
# (lock_steal_replay_stall_ms). Once A is inside it, B closes its fd:
#   1. B's close returns in under 2 s;
#   2. A then gets the lock.
#
# DISCRIMINATION: the control, in-suite -- lock_steal_holds_mutex=1, the
# old steal: B's close waits out the stall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in lock_steal_holds_mutex lock_steal_replay_stall_ms; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt lsdm)"
ct_track mnt "$MNT"
compress_timing
ct_param_set lock_steal_holds_mutex 0
ct_param_set lock_steal_replay_stall_ms 0

# round <holds 0|1> -> "<B close ms> <A locked yes|no>"
round() {
    local img dev ino goa gob aout bout pa pb ms alock=no
    img="$(ct_image 560 "lsdm$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    echo image >"$MNT/vm.img"
    ino="$(stat -c %i "$MNT/vm.img")"
    sync
    goa="$(ct_tmp "lsdm-goa$1")"; gob="$(ct_tmp "lsdm-gob$1")"
    aout="$(ct_tmp "lsdm-a$1")"; bout="$(ct_tmp "lsdm-b$1")"
    rm -f "$goa" "$gob"
    python3 -c 'import fcntl,os,sys,time
fd = os.open(sys.argv[1], os.O_RDWR)
print("open", flush=True)
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
fcntl.flock(fd, fcntl.LOCK_EX)
print("locked", flush=True)
time.sleep(30)' "$MNT/vm.img" "$goa" >"$aout" 2>&1 &
    pa=$!
    python3 -c 'import os,sys,time
fd = os.open(sys.argv[1], os.O_RDWR)
print("open", flush=True)
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
t = time.monotonic()
os.close(fd)
print("closed", int((time.monotonic() - t) * 1000), flush=True)' "$MNT/vm.img" "$gob" >"$bout" 2>&1 &
    pb=$!
    wait_for 10 'grep -q open "$aout" && grep -q open "$bout"' || { echo "setup-open no"; kill -9 "$pa" "$pb"; return; }
    poke_dead_peer "$img" 1 aa
    "$LOCK_POKE" "$img" "$ino" 1 1 >/dev/null
    echo "$1" >$P/lock_steal_holds_mutex
    echo 8000 >$P/lock_steal_replay_stall_ms
    touch "$goa"
    # A inside the steal's stall (the dead row must first be judged stale)
    wait_for 40 'grep -q cetrafs_lock_arm_stale_steal "/proc/$pa/stack" 2>/dev/null' ||
        { echo "setup-steal no"; kill -9 "$pa" "$pb"; echo 0 >$P/lock_steal_replay_stall_ms; echo 0 >$P/lock_steal_holds_mutex; ct_umount "$MNT"; return; }
    sleep 0.5
    touch "$gob"
    wait_for 15 'grep -q closed "$bout"' || true
    ms="$(sed -n 's/^closed //p' "$bout")"
    wait_for 15 'grep -q locked "$aout"' && alock=yes
    echo 0 >$P/lock_steal_replay_stall_ms
    echo 0 >$P/lock_steal_holds_mutex
    kill -9 "$pa" "$pb" 2>/dev/null || true
    wait "$pa" "$pb" 2>/dev/null || true
    "$(ct_helper node_poke)" "$img" 1 0 bb 0 >/dev/null
    ct_umount "$MNT"
    echo "${ms:-none} $alock"
}

read -r CMS CA <<<"$(round 1)"
log "control (mutex held): B's close took $CMS ms; A locked: $CA"
read -r MS A <<<"$(round 0)"
log "fixed: B's close took $MS ms; A locked: $A"
[ "$CMS" != none ] && [ "$CMS" -ge 4000 ] && pass "control: holding the mutex, B's close waited out the steal ($CMS ms)" ||
    fail "control: B's close took $CMS ms with the mutex held -- the hazard did not reproduce"
[ "$MS" != none ] && [ "$MS" -lt 2000 ] && pass "1: B's close returned in $MS ms while the steal fenced and replayed" ||
    fail "1: B's close took $MS ms"
[ "$A" = yes ] && pass "2: A then took the dead holder's lock" || fail "2: A never got the lock"
ct_exit
