#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a killed process does not wait in close for another task's hold of the file's lock_mutex
#
# ->release took lock_mutex uninterruptibly. Another local task can hold
# it for seconds (an open across a fence or a peer's lock, a suspend
# waiting out a defrag), and a process killed meanwhile sat in D state
# in its exit path for all of it. A dying task that finds the mutex busy
# now hands its close to a work item on the mount's cold_wq, with an
# inode reference, and exits (kmod/lock.c, cetrafs_lock_release()).
#
# Staged: lock_open_pause_ms pauses an open while it holds lock_mutex.
#
#  1. a reader holding the file is SIGKILLed during that pause: it is
#     gone at once, and the close is counted as deferred; when the
#     pause ends the deferred close has withdrawn the reader's
#     presence (read_open_nodes back to 0 once every fd is closed).
#  2. the drain: the same, then a lazy unmount while the deferred close
#     is still queued behind the paused open -- kill_sb must run it
#     before the inode cache goes (no "Busy inodes after unmount",
#     which the harness fails on).
#  3. control (close_defer_off=1): the killed reader stays until the
#     pause ends.
#  4. a reader that EXITS NORMALLY during the pause is not deferred: it
#     stays until its close has run. "The process is gone" must still
#     mean "its lock is released" for a VM stopped cleanly and started
#     on another host; only a killed one may leave its close behind.
#
# Not tested, said plainly: the sentinel a deferred close leaves in
# explicit_lock_file. The bug it closes needs a new file at the freed
# file's exact address, which no test can arrange, and without that a
# new fd's flock is refused either way.
#
# DISCRIMINATION: 3 is the old path, selected by the knob.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 closedying)"
MNT="$(ct_mnt closedying)"
ct_track mnt "$MNT"
ct_param_set close_defer_off 0
ct_param_set lock_open_pause_ms 0
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo content >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
secs() { date +%s.%N; }
took() { awk -v a="$1" -v b="$(secs)" 'BEGIN { printf "%.1f", b - a }'; }
readers() { sed -n 's/.*readers=\(0x[0-9a-f]*\).*/\1/p' <<<"$("$LOCK_POKE" "$DEV" "$INO")"; }

# <tag> <expect: fast|slow>: a reader is killed while an open pauses holding lock_mutex
kill_during_pause() {
    local R O T t
    python3 -c 'import os,sys,time
fd = os.open(sys.argv[1], os.O_RDONLY); time.sleep(600)' "$MNT/f" &
    R=$!
    sleep 0.5
    ct_param_set lock_open_pause_ms 6000
    python3 -c 'import os,sys
os.close(os.open(sys.argv[1], os.O_RDONLY))' "$MNT/f" &
    O=$!
    sleep 1 # the open is now paused holding lock_mutex
    T="$(secs)"
    kill -9 "$R"
    for _ in $(seq 1 100); do kill -0 "$R" 2>/dev/null || break; sleep 0.1; done
    t="$(took "$T")"
    wait "$R" 2>/dev/null || true
    echo "$t" >"$MNT.t"
    wait "$O" 2>/dev/null || true
}

# ------------------------------------------------------------------ 1
log "1: a killed reader's close does not wait for a paused open"
D0="$(info close_deferrals)"
kill_during_pause
t="$(cat "$MNT.t")"
awk -v t="$t" 'BEGIN { exit !(t < 1.5) }' && pass "1: the killed reader was gone in ${t}s" ||
    fail "1: the killed reader took ${t}s to go"
[ "$(info close_deferrals)" -gt "$D0" ] && pass "1: its close was handed to a work item" ||
    fail "1: no close was deferred -- the reader went some other way"
sleep 1
r="$(readers)"
[ "$r" = 0x0 ] && pass "1: the deferred close withdrew the reader's presence" ||
    fail "1: read_open_nodes=$r after every fd closed"

# ------------------------------------------------------------------ 3
log "3: control -- with deferral off the killed reader waits for the pause"
ct_param_set close_defer_off 1
kill_during_pause
t="$(cat "$MNT.t")"
awk -v t="$t" 'BEGIN { exit !(t >= 3) }' && pass "3: control: the killed reader stayed ${t}s, until the pause ended" ||
    fail "3: control: the killed reader was gone in ${t}s with deferral off -- the suite cannot tell the two apart"
ct_param_set close_defer_off 0
rm -f "$MNT.t"

# ------------------------------------------------------------------ 4
log "4: a reader that exits normally during the pause is not deferred"
python3 -c 'import os,sys,time
fd = os.open(sys.argv[1], os.O_RDONLY); time.sleep(1.5); sys.exit(0)' "$MNT/f" &
R=$!
sleep 0.5
ct_param_set lock_open_pause_ms 6000
python3 -c 'import os,sys
os.close(os.open(sys.argv[1], os.O_RDONLY))' "$MNT/f" &
O=$!
D0="$(info close_deferrals)"
T="$(secs)"
wait "$R" 2>/dev/null || true
t="$(took "$T")"
wait "$O" 2>/dev/null || true
[ "$(info close_deferrals)" = "$D0" ] && pass "4: its close was not deferred" ||
    fail "4: a normal exit's close was handed to the work item"
awk -v t="$t" 'BEGIN { exit !(t >= 3) }' && pass "4: it stayed ${t}s, until its close had run" ||
    fail "4: it was gone in ${t}s, before its close could have run"

# ------------------------------------------------------------------ 2
log "2: a lazy unmount while the deferred close is queued"
python3 -c 'import os,sys,time
fd = os.open(sys.argv[1], os.O_RDONLY); time.sleep(600)' "$MNT/f" &
R=$!
sleep 0.5
ct_param_set lock_open_pause_ms 6000
python3 -c 'import os,sys
os.close(os.open(sys.argv[1], os.O_RDONLY))' "$MNT/f" &
O=$!
sleep 1
D0="$(info close_deferrals)"
kill -9 "$R"; wait "$R" 2>/dev/null || true
[ "$(info close_deferrals)" -gt "$D0" ] && pass "2: setup: the close is deferred behind the paused open" ||
    { fail "2: setup: no deferred close"; wait "$O" 2>/dev/null || true; ct_exit; }
mark="$(dmesg_mark)"
umount -l "$MNT"
wait "$O" 2>/dev/null || true
for _ in $(seq 1 50); do dmesg_since "$mark" | grep -q "unmounted" && break; sleep 0.2; done
dmesg_since "$mark" | grep -q "unmounted" && pass "2: the lazy unmount completed once the open closed" ||
    fail "2: the volume never finished unmounting"
dmesg_since "$mark" | grep -q "Busy inodes" && fail "2: busy inodes after unmount -- the deferred close was not drained" ||
    pass "2: no busy inodes: kill_sb ran the deferred close first"

out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
