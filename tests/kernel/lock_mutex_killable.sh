#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a flock queued behind another's reclaim of a stale lock can be killed
#
# The per-inode lock_mutex is held across a stale holder's fence and
# journal replay (up to ~210 s). flock, lock suspend/resume and the
# defrag pin then waited for it in a plain mutex_lock: unkillable, in D,
# for as long as that took (audit R21). They wait killably now; the
# heartbeat's retry passes try the mutex and re-queue instead of
# queueing behind it. NOT covered: the killed process's own close, which
# must take lock_mutex to publish and release, still waits for it.
#
# Staged on a nofilelock mount: row 1 holds the file's lock and is
# stale; flock A reclaims it and is held inside lock_mutex just before
# the swap (reclaim_stall_before_swap_ms); flock B, on a second open of
# the same file, queues behind A and is killed.
#
# DISCRIMINATION: the setup check requires B to be blocked (D) while A
# still holds the stall. The reverted-fix control (plain mutex_lock in
# cetrafs_lock_explicit_acquire()) has not been run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms ] || { skip "reclaim_stall_before_swap_ms is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 lmk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lmk)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo image >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
sync

# <tag> <go-file>: open now (while the lock is free -- an open is
# refused under a peer's lock), flock LOCK_EX once <go-file> exists.
flocker() {
    exec python3 -c 'import fcntl,os,sys,time
fd = os.open(sys.argv[1], os.O_RDWR)
print(sys.argv[2], "open", flush=True)
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)
fcntl.flock(fd, fcntl.LOCK_EX)
print(sys.argv[2], "locked", flush=True)
time.sleep(30)' "$MNT/vm.img" "$1" "$2"
}
GOA="$(ct_tmp lmk-goa)"; GOB="$(ct_tmp lmk-gob)"
rm -f "$GOA" "$GOB"
AOUT="$(ct_tmp lmk-a)"; BOUT="$(ct_tmp lmk-b)"
flocker A "$GOA" >"$AOUT" 2>&1 &
PA=$!
flocker B "$GOB" >"$BOUT" 2>&1 &
PB=$!
wait_for 10 'grep -q open "$AOUT" && grep -q open "$BOUT"' || { fail "setup: the opens did not happen: $(cat "$AOUT" "$BOUT")"; kill -9 "$PA" "$PB"; ct_exit; }

# Through the backing file: a poke through $DEV sits in its page cache,
# where the kernel's uncached reads do not see it.
poke_dead_peer "$IMG" 1 aa
"$LOCK_POKE" "$IMG" "$INO" 1 1 >/dev/null
"$LOCK_POKE" "$IMG" "$INO" | grep -q "owner=1 mode=1" || { fail "setup: the lock is not row 1's"; ct_exit; }
ct_param_set reclaim_stall_before_swap_ms 10000
MARK="$(dmesg_mark)"
touch "$GOA"
wait_for 30 'dmesg_since "$MARK" | grep -q "flock: ino=$INO reclaiming a stale lock from node 1"' ||
    { fail "setup: A never reached the reclaim ($(cat "$AOUT"))"; kill -9 "$PA" "$PB" 2>/dev/null; ct_param_set reclaim_stall_before_swap_ms 0; ct_exit; }
touch "$GOB"
sleep 1.5
ST="$(awk '{print $3}' "/proc/$PB/stat" 2>/dev/null || echo gone)"
log "B is in state $ST: $(head -8 /proc/$PB/stack 2>/dev/null | tr '\n' ' ')"
if [ "$ST" != D ]; then
    fail "setup: B is not waiting on the mutex (state $ST; A state $(awk '{print $3}' "/proc/$PA/stat" 2>/dev/null); A: $(tr '\n' ' ' <"$AOUT"); B: $(tr '\n' ' ' <"$BOUT"); $(cat /proc/$PA/stack 2>/dev/null | head -4 | tr '\n' ' '))"
else
    kill -9 "$PB"
    sleep 1
    STK="$(cat "/proc/$PB/stack" 2>/dev/null | tr '\n' ' ')"
    A_ALIVE=0
    [ "$(awk '{print $3}' "/proc/$PA/stat" 2>/dev/null)" = D ] && A_ALIVE=1
    log "1 s after SIGKILL: B $( [ -n "$STK" ] && echo "at: $STK" || echo gone); A still inside the reclaim: $A_ALIVE"
    [ "$A_ALIVE" = 1 ] || fail "setup: the reclaim was over before the kill could be judged"
    if grep -q cetrafs_lock_explicit_acquire <<<"$STK"; then
        fail "the queued flock is still waiting for lock_mutex 1 s after SIGKILL"
    else
        pass "SIGKILL ended the queued flock's wait for lock_mutex while the reclaim still held it"
    fi
    # Its close still takes lock_mutex: close publishes and releases
    # (cetrafs_lock_release()), so a dying process waits there -- not
    # claimed killable here.
    wait "$PB" 2>/dev/null || true
fi
kill -9 "$PA" "$PB" 2>/dev/null || true
wait "$PA" "$PB" 2>/dev/null || true
ct_param_set reclaim_stall_before_swap_ms 0
"$(ct_helper node_poke)" "$IMG" 1 0 bb 0 >/dev/null
ct_umount "$MNT"
ct_exit
