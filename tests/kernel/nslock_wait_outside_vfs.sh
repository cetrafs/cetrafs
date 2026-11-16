#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# waiting for a peer's namespace lock does not hold the directory's VFS lock
#
# Every namespace operation is called with the parent directory's
# i_rwsem held. It used to wait out a peer's namespace lock in there --
# up to ~12 s -- so everything queued on that i_rwsem waited too: an
# `ls` of the directory, a lookup of any uncached name in it, every
# other create. Now an operation the VFS called tries once, and if a
# peer holds the lock it returns -ERESTARTNOINTR with a task_work that
# sleeps one interval outside every lock; the system call restarts
# (kmod/nslock.c, cetrafs_nslock_acquire_set_vfs()).
#
# The peer is staged: a registered Node Registry row that has not gone
# stale yet (stale_secs 60), named as the directory's ns_lock_owner.
#
#  1. a mkdir in the directory waits; meanwhile `ls` of the directory
#     returns at once, and the waiter is counted as restarting;
#     once the peer lets go the mkdir completes -- a restarted call
#     succeeds, it is not an error to the caller.
#  2. the budget is unchanged: a peer that never lets go (and does not
#     go stale) ends the wait with EBUSY after ~12 s, not never.
#  3. the waiter is killable.
#  4. control (nslock_restart_off=1): the old in-lock wait, and the `ls`
#     blocks behind it.
#
# DISCRIMINATION: 4 is the old code path, selected by the knob.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 nswait)"
MNT="$(ct_mnt nswait)"
WORK="$(ct_mnt nswaitwork)"
ct_track mnt "$MNT"
ct_param_set nslock_restart_off 0
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
ct_param_set stale_secs 60
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/a"
sync
DINO="$(stat -c %i "$MNT/d")"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
peer_holds() { "$LOCK_POKE" "$DEV" "$DINO" --ns 1 >/dev/null; }
peer_lets_go() { "$LOCK_POKE" "$DEV" "$DINO" --ns 65535 >/dev/null; }
secs() { date +%s.%N; }
took() { awk -v a="$1" -v b="$(secs)" 'BEGIN { printf "%.1f", b - a }'; }

# The peer registers after the mount (planted before, the mount's gate
# would watch it for a whole window first).
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
peer_holds
# And beats: a live peer holding its lock. A silent one is waited out
# until it goes stale instead (nslock_silent_holder.sh).
ct_beat_row "$DEV" 1

# ------------------------------------------------------------------ 1
log "1: a mkdir waits for the peer's lock; ls of the directory does not wait for it"
R0="$(info nslock_restarts)"
( mkdir "$MNT/d/x" 2>"$WORK/x.err"; echo $? >"$WORK/x.rc" ) &
A=$!
sleep 1.5
if ! kill -0 "$A" 2>/dev/null || [ -e "$MNT/d/x" ]; then
    fail "1: setup: the mkdir did not wait for the peer's lock ($(cat "$WORK/x.rc" 2>/dev/null) $(cat "$WORK/x.err" 2>/dev/null))"
    ct_exit
fi
pass "1: setup: the mkdir is waiting for the peer's lock"
T="$(secs)"
if timeout 5 ls "$MNT/d" >/dev/null; then
    t="$(took "$T")"
    awk -v t="$t" 'BEGIN { exit !(t < 1.5) }' && pass "1: ls of the directory returned in ${t}s while the mkdir waited" ||
        fail "1: ls of the directory took ${t}s while the mkdir waited"
else
    fail "1: ls of the directory was still blocked after 5 s"
fi
[ "$(info nslock_restarts)" -gt "$R0" ] && pass "1: the waiter restarted its call ($(info nslock_restarts) restarts)" ||
    fail "1: no restart was counted -- the mkdir waited some other way"
peer_lets_go
for _ in $(seq 1 50); do kill -0 "$A" 2>/dev/null || break; sleep 0.1; done
wait "$A" 2>/dev/null || true
[ "$(cat "$WORK/x.rc" 2>/dev/null)" = 0 ] && [ -d "$MNT/d/x" ] &&
    pass "1: once the peer let go, the restarted mkdir succeeded" ||
    fail "1: the mkdir after the peer let go: rc=$(cat "$WORK/x.rc" 2>/dev/null) $(cat "$WORK/x.err" 2>/dev/null)"

# ------------------------------------------------------------------ 2
log "2: a peer that never lets go ends the wait with EBUSY, on the old budget"
peer_holds
T="$(secs)"
out="$(mkdir "$MNT/d/y" 2>&1)" && rc=0 || rc=$?
t="$(took "$T")"
if [ "$rc" != 0 ] && grep -qi "busy" <<<"$out" && awk -v t="$t" 'BEGIN { exit !(t >= 10 && t < 20) }'; then
    pass "2: EBUSY after ${t}s"
else
    fail "2: rc=$rc after ${t}s: $out"
fi

# ------------------------------------------------------------------ 3
log "3: the waiter is killable"
mkdir "$MNT/d/z" 2>/dev/null &
A=$!
sleep 1
kill -0 "$A" 2>/dev/null || { fail "3: setup: the mkdir did not wait"; ct_exit; }
T="$(secs)"
kill -9 "$A"
wait "$A" 2>/dev/null || true
t="$(took "$T")"
awk -v t="$t" 'BEGIN { exit !(t < 1.5) }' && pass "3: SIGKILL ended the wait in ${t}s" ||
    fail "3: the killed waiter took ${t}s to go"
[ -e "$MNT/d/z" ] && fail "3: the killed mkdir created its directory anyway" || pass "3: and created nothing"

# ------------------------------------------------------------------ 4
log "4: control -- the old wait inside the VFS lock blocks ls"
ct_param_set nslock_restart_off 1
mkdir "$MNT/d/w" 2>/dev/null &
A=$!
sleep 1
if timeout 3 ls "$MNT/d" >/dev/null; then
    fail "4: control: ls returned while the mkdir waited in the lock -- the suite cannot tell the two apart"
else
    pass "4: control: with the wait inside the VFS lock, ls of the directory blocks behind it"
fi
peer_lets_go
wait "$A" 2>/dev/null || true
ct_param_set nslock_restart_off 0

ls "$MNT/d" >/dev/null
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null # the staged peer leaves, or fsck waits on it
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
