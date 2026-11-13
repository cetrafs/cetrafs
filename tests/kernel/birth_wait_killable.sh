#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create waiting out a peer's reclaim of the number it took can be killed
#
# A create takes the lowest free inode number, and if that number's record
# is held by a peer's reclaim (a scrub mid-claim) it waits for the release:
# cetrafs_birth_await_release(), up to 2 s, in killable sleeps (audit L21,
# class 20). Nothing made that wait reachable from a test -- which peer
# holds which number is decided by the allocator -- so the wait had no
# suite, only the source check.
#
# birth_hold_ms makes every birth see its record held for that long, so
# the create sits in the wait deterministically. The first part kills a
# create 500 ms into a 2 s hold: it must die well inside the hold.
#
# The control (second part) sets birth_wait_uninterruptible, the sleep as
# it was before the change. The same kill must then wait out the hold,
# which is what this suite is here to notice.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/birth_hold_ms ] || { skip "birth_hold_ms is missing"; ct_exit; }

DEV="$(ct_dev 560 birthkill)"
MNT="$(ct_mnt birthkill)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo seed >"$MNT/seed"
sync

# Milliseconds from SIGKILL until the process is gone.
kill_time() {
    local t0 t1
    t0="$(date +%s%N)"
    kill -9 "$1" 2>/dev/null || true
    while kill -0 "$1" 2>/dev/null; do sleep 0.02; done
    t1="$(date +%s%N)"
    echo $(((t1 - t0) / 1000000))
}

# create_wait <name> <hold_ms>: start a create under a hold, kill it at 500 ms.
# Prints "gone" if it had already finished, else the kill time in ms.
create_wait() {
    local P MS
    ct_param_set birth_hold_ms "$2"
    (touch "$MNT/$1" 2>/dev/null) &
    P=$!
    sleep 0.5
    if ! kill -0 "$P" 2>/dev/null; then
        ct_param_set birth_hold_ms 0
        echo gone
        return 0
    fi
    MS="$(kill_time "$P")"
    wait "$P" 2>/dev/null || true
    ct_param_set birth_hold_ms 0
    echo "$MS"
}

log "1: a create waiting out a peer's reclaim dies on SIGKILL"
MS="$(create_wait waitA 2000)"
[ "$MS" = gone ] && { fail "1: setup: the create finished before the kill -- the hold did not wait it"; ct_exit; }
pass "1: setup: the create was still waiting 500 ms in"
[ "$MS" -lt 1000 ] && pass "1: it died ${MS} ms after SIGKILL, well inside the 2 s hold" ||
    fail "1: the create took ${MS} ms to die behind a 2 s hold -- the wait is deaf to SIGKILL"

# The killed create leaves its bit set (a leak the scrub reclaims), so the
# next create must still work: a number is not handed out twice nor wedged.
if touch "$MNT/afterkill" && [ -e "$MNT/afterkill" ]; then
    pass "1: the mount takes creates afterwards"
else
    fail "1: a create fails after the killed one"
fi

log "2: control -- the same wait, uninterruptible as it was"
ct_param_set birth_wait_uninterruptible 1
MS="$(create_wait waitB 2000)"
ct_param_set birth_wait_uninterruptible 0
if [ "$MS" != gone ] && [ "$MS" -ge 1000 ]; then
    pass "control: uninterruptible, the kill took ${MS} ms to land -- the hold outlived it"
else
    fail "control: the uninterruptible wait died in ${MS} ms -- the control does not reproduce the deaf wait"
fi

ct_umount "$MNT" || umount -l "$MNT"
ct_exit
