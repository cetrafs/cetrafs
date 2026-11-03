#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a process waiting on a peer's namespace lock, or behind a stale-holder replay, can be killed
#
# Two waits held processes in D state, deaf to SIGKILL:
#
#   * The namespace-lock acquire retries a peer-held lock for its whole
#     budget, 600 x 20 ms, sleeping uninterruptibly between attempts --
#     about 12 seconds. A second create in the same directory queues
#     behind it on the directory's i_rwsem, which the VFS takes
#     uninterruptibly and holds across ->create: nothing in cetrafs can
#     make THAT wait killable, so the queue drains only as fast as its
#     head gives up. Killing the head must therefore be immediate, and
#     the next in line, now retrying for itself, must die as fast.
#   * cetrafs_lock_open() holds the file's lock_mutex across a stale
#     holder's fence and journal replay, and a second open of the same
#     file waited for it uninterruptibly.
#
# Now the retry loops stop on a fatal signal and both local mutexes are
# taken killable. Nothing has been changed by the time either returns.
#
# The peer is node 1, registered with a fresh timestamp as nslock.sh
# does: a row nobody has watched yet counts as live for a full window,
# so the acquire keeps retrying. lock_open_pause_ms holds lock_mutex.
#
# DISCRIMINATION: without the change each killed process lives on until
# its wait ends -- ~12 s for the namespace lock, the pause for the open.
# The ns_mutex itself is taken killable too, but every caller that can
# contend for it from user context already holds a VFS inode lock on the
# same inode, so no test from userspace reaches that wait.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lock_open_pause_ms ] || { skip "lock_open_pause_ms is missing"; ct_exit; }

LPOKE="$(ct_helper inode_lock_poke)"
IPOKE="$(ct_helper inode_block_poke)"
NPOKE="$(ct_helper node_poke)"
DEV="$(ct_dev 560 killwait)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt killwait)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# kill_time <pid>: SIGKILL it and print how many ms it took to go
kill_time() {
    local t0 t1
    t0="$(date +%s%N)"
    kill -9 "$1" 2>/dev/null || true
    while kill -0 "$1" 2>/dev/null; do sleep 0.05; done
    t1="$(date +%s%N)"
    echo $(((t1 - t0) / 1000000))
}

# ---------------------------------------------------------------- 1
log "1: creates in a directory whose namespace lock a live peer holds"
mkdir "$MNT/d"
DINO="$(stat -c %i "$MNT/d")"
sync
"$LPOKE" "$BACK" "$DINO" --ns 1 >/dev/null
"$NPOKE" "$BACK" 1 1 bb "$(date +%s)" >/dev/null
"$IPOKE" "$BACK" bumpseq "$DINO" 2>/dev/null
blockdev --flushbufs "$DEV"
(touch "$MNT/d/a" 2>/dev/null) &
P1=$!
sleep 1
(touch "$MNT/d/b" 2>/dev/null) &
P2=$!
sleep 1
if kill -0 "$P1" 2>/dev/null && kill -0 "$P2" 2>/dev/null; then
    pass "1: setup: both creates are waiting (one on the peer's lock, one behind it in the VFS)"
else
    fail "1: setup: a create finished -- node 1's lock was not honoured"
    ct_exit
fi
MS="$(kill_time "$P1")"
[ "$MS" -lt 2000 ] && pass "1: the one retrying the peer's lock died ${MS} ms after SIGKILL" ||
    fail "1: the one retrying the peer's lock took ${MS} ms to die"
sleep 1
grep -q cetrafs_nslock_acquire "/proc/$P2/stack" 2>/dev/null &&
    pass "1: setup: the next in line is now retrying the peer's lock itself" ||
    { fail "1: setup: the second create is not in the nslock retry: $(head -2 "/proc/$P2/stack" 2>&1 | tr '\n' ' ')"; ct_exit; }
MS="$(kill_time "$P2")"
[ "$MS" -lt 2000 ] && pass "1: and it died ${MS} ms after SIGKILL" ||
    fail "1: it took ${MS} ms to die"
wait 2>/dev/null || true
"$LPOKE" "$BACK" "$DINO" --ns 65535 >/dev/null
"$IPOKE" "$BACK" bumpseq "$DINO" 2>/dev/null
blockdev --flushbufs "$DEV"
touch "$MNT/d/c" && pass "1: the directory works once the peer lets go" || fail "1: d refuses creates afterwards"

# ---------------------------------------------------------------- 2
log "2: a second open waiting behind one that holds lock_mutex"
echo data >"$MNT/f"
sync
ct_param_set lock_open_pause_ms 8000
(cat "$MNT/f" >/dev/null) &
P1=$!
sleep 1
(cat "$MNT/f" >/dev/null) &
P2=$!
sleep 1
kill -0 "$P2" 2>/dev/null && pass "2: setup: the second open is waiting" ||
    { fail "2: setup: the second open did not wait"; ct_exit; }
MS="$(kill_time "$P2")"
[ "$MS" -lt 2000 ] && pass "2: it died ${MS} ms after SIGKILL" || fail "2: it took ${MS} ms to die"
wait "$P1" 2>/dev/null || true
ct_param_set lock_open_pause_ms 0
[ "$(cat "$MNT/f")" = data ] && pass "2: the file opens normally afterwards" || fail "2: the file no longer opens"
ct_exit
