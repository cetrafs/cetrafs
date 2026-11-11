#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAS waiting behind the no-CAW fallback's mutex can be killed
#
# Without COMPARE AND WRITE every local CAS serialises on one node-local
# mutex, held across a forced-fresh read and a synced write. It was
# taken with mutex_lock(): a stalled device left every other CAS on the
# node waiting uninterruptibly behind it, kill -9 included, though the
# CAS path already returns -EINTR (nothing issued) on the CAW side for
# exactly that (audit 2026-11-11 C4). It now waits killably whenever its
# caller may be interrupted.
#
# The rig: cas_nocaw_stall_ms holds the mutex 8 s inside one create's
# swap; a second create, in another directory, queues behind it and is
# sent SIGKILL.
#
#  1. the second create is gone within 2 s of the kill, while the first
#     is still holding the mutex.
#  2. the first finishes, the volume is consistent.
#
# DISCRIMINATION (2026-11-11, mutex_lock() as before): 1 waits until
# the holder lets go, ~6 s after the kill.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters/cas_nocaw_stall_ms
[ -w "$P" ] || { skip "cas_nocaw_stall_ms is missing"; ct_exit; }

IMG="$(ct_image 560 casmtx)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt casmtx)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q 'available=no' "$(ct_procdir "$DEV")/properties" ||
    { fail "setup: the loop device is driven with CAW"; ct_exit; }
mkdir "$MNT/d1" "$MNT/d2"
sync

ct_param_set cas_nocaw_stall_ms 8000
bash -c ': >"$1/d1/a"' _ "$MNT" & A=$!
for _ in $(seq 1 40); do [ "$(cat "$P")" = 0 ] && break; sleep 0.05; done
[ "$(cat "$P")" = 0 ] || { fail "setup: the first create never reached a no-CAW swap"; echo 0 >"$P"; ct_exit; }
bash -c ': >"$1/d2/b"' _ "$MNT" & B=$!
sleep 1
kill -0 "$B" 2>/dev/null || { fail "setup: the second create did not queue behind the first"; ct_exit; }
kill -0 "$A" 2>/dev/null || { fail "setup: the holder finished before the kill"; ct_exit; }
T0="$(date +%s%N)"
kill -9 "$B"
while kill -0 "$B" 2>/dev/null; do sleep 0.05; done
T1="$(date +%s%N)"
HOLDING=no; kill -0 "$A" 2>/dev/null && HOLDING=yes
MS=$(((T1 - T0) / 1000000))
[ "$MS" -lt 2000 ] && [ "$HOLDING" = yes ] && pass "1: the waiter died ${MS} ms after SIGKILL, the holder still holding" ||
    fail "1: the waiter took ${MS} ms to die (holder still holding: $HOLDING)"
wait "$A" && pass "2: the holder's create completed" || fail "2: the holder's create failed"
wait "$B" 2>/dev/null || true
[ -e "$MNT/d1/a" ] || fail "2: d1/a is missing"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "2: fsck clean" || fail "2: fsck: $(ct_fsck "$DEV" 2>&1 | grep -m2 ERR)"
losetup -d "$DEV"
ct_exit
