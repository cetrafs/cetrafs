#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# long waits a syscall can be parked in are killable, and a signal does not cut them short
#
# A. A namespace-lock acquire that finds a deferred-release retry pass in
#    flight waits it out before it drops its own entry. It waited in a
#    plain mutex_lock -- behind up to 32 CASes on a failing device, while
#    holding the inode's ns_mutex and the VFS directory lock -- so neither
#    it nor anything queued behind it could be killed (audit R21). The
#    wait is now killable.
# B. A mount waiting for a peer's replay claim counted its waiting by
#    adding 500 ms per msleep_interruptible(); a pending NON-fatal signal
#    makes that sleep return at once, so the whole cap burned in a burst
#    of claim CASes and the mount failed -EBUSY "after 210000 ms" in
#    well under a second (R21). Elapsed time now comes from the clock and
#    the sleep is killable, not interruptible.
#
# DISCRIMINATION: against the old code A's killed process stays in D
# state until the stalled pass ends, and B's mount fails at once.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/nslock_retry_stall_ms ] || { skip "nslock_retry_stall_ms is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
ct_param_set hb_interval_secs 1

IMG="$(ct_image 560 rcwait)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rcwait)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/a" "$MNT/b"
: >"$MNT/a/f"
sync

log "A: an acquire parked behind a stalled release-retry pass"
# A release that does not commit leaves a deferred entry; the heartbeat
# retries it, and the stall holds that pass inside its bracket. Through a
# chmod, whose release has nothing STAGED (a lost staged update stops the
# mount instead -- nslock_staged_publish_lost.sh).
ct_param_set nslock_release_fail 1
chmod 600 "$MNT/a/f" 2>/dev/null || true
ct_param_set nslock_release_fail 0
ct_param_set nslock_retry_stall_ms 10000
MARK="$(dmesg_mark)"
wait_for 10 'dmesg_since "'"$MARK"'" | grep -q "release retry pass stalled"' ||
    { fail "setup: no retry pass started"; ct_exit; }
ct_param_set nslock_retry_stall_ms 0
touch "$MNT/b/y" &
P=$!
sleep 1
kill -0 "$P" 2>/dev/null || { fail "setup: the create did not wait on the retry pass"; ct_exit; }
T0="$(date +%s.%N)"
kill -9 "$P"
wait "$P" 2>/dev/null || true
T="$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')"
log "A: the killed create exited ${T}s after SIGKILL (pass stalled for 10 s)"
awk -v t="$T" 'BEGIN { exit !(t < 3) }' && pass "A: a create waiting on a retry pass dies when killed" ||
    fail "A: the killed create stayed ${T}s -- it waited out the pass uninterruptibly"
sleep 9 # let the stalled pass finish before unmounting
ct_umount "$MNT"

log "B: a mount waiting on a live replay claim, with a signal pending"
"$JPOKE" "$DEV" "$NID" --claim $(((NID + 1) % 4)) >/dev/null
blockdev --flushbufs "$DEV"
ct_param_set force_live_replay_claim 1
RES="$(ct_tmp rcw-res)"
python3 - "$DEV" "$MNT" "$RES" <<'PY' &
import ctypes, os, signal, sys
signal.signal(signal.SIGUSR1, lambda *a: None)   # handled: pending, never fatal
libc = ctypes.CDLL(None, use_errno=True)
r = libc.mount(sys.argv[1].encode(), sys.argv[2].encode(), b"cetrafs", 0, None)
open(sys.argv[3], "w").write("%d %d\n" % (r, ctypes.get_errno()))
PY
MP=$!
sleep 2
kill -USR1 "$MP"
sleep 4
STILL=0; [ ! -s "$RES" ] && STILL=1
"$JPOKE" "$DEV" "$NID" --claim release >/dev/null
blockdev --flushbufs "$DEV"
wait "$MP" || true
ct_param_set force_live_replay_claim 0
log "B: mount result $(cat "$RES" 2>/dev/null) (rc errno)"
[ "$STILL" = 1 ] && pass "B: 4 s after a signal the mount was still waiting on the claim" ||
    fail "B: the mount gave up right after a non-fatal signal: $(cat "$RES")"
grep -q "^0 " "$RES" && pass "B: and completed once the claim was released" ||
    fail "B: the mount failed: $(cat "$RES")"
mountpoint -q "$MNT" && ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
