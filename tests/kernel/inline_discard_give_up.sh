#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# -o discard gives up rather than make anyone wait: under space pressure, and at unmount
#
# Inline discard is best effort; allocating and unmounting are not. The
# worker holds each run it discards out of the allocator's reach for the
# length of its UNMAP, so on a volume that has just run out of space it
# drops what is queued instead (an ENOSPC must never wait on the array).
# At unmount the queue and the worker are drained before the mount's
# state is torn down (rule 20): a worker mid-pass stops at its next
# range, and a queue not yet started is dropped with its work cancelled.
#
#  1. pressure: fill the volume until an allocation fails ENOSPC, punch
#     a hole at once. The worker drops the range (counted, logged "no
#     space") and issues nothing.
#  2. NEGATIVE CONTROL, inline_discard_never_give_up: the same, and the
#     worker discards -- so 1's silence is the give-up, not an idle worker.
#  3. unmount mid-pass: five ranges queued, the worker held 3 s on each
#     claim. The unmount stops it after the range in hand.
#  4. NEGATIVE CONTROL, inline_discard_never_give_up: the unmount waits
#     for every range -- so 3's quick unmount is the give-up.
#  5. unmount with a queue the worker has not started (a 3 s delay):
#     dropped at once and the work cancelled -- waited out past the
#     delay, nothing ran against the freed mount: no "Busy inodes", no
#     oops, and the module unloads clean (the harness checks at exit).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in inline_discard_delay_ms inline_discard_stall_ms inline_discard_never_give_up; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

IMG="$(ct_image 560 idgive)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt idgive)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set inline_discard_delay_ms 200

info() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/info"; }
mnt() {
    local o="${CT_MOUNT_OPTS:-}"
    ct_mkfs_small "$DEV" >/dev/null
    CT_MOUNT_OPTS="${o:+$o,}discard" ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
}

# fill: preallocate until an allocation fails with ENOSPC.
fill() {
    local i
    for i in $(seq 1 200); do
        fallocate -l 16M "$MNT/pad$1.$i" 2>/dev/null || return 0
    done
    fail "$1 setup: 200 x 16 MiB preallocated and no ENOSPC"
    ct_exit
}

# pressure_round <tag> <never_give_up>. Sets DC (discards issued), DG
# (ranges given up), LOG.
pressure_round() {
    local c0 g0 mark
    mnt
    dd if=/dev/urandom of="$MNT/f" bs=1M count=16 conv=fsync status=none
    sync
    ct_param_set inline_discard_never_give_up "$2"
    fill "$1"
    sleep 1 # what the failed preallocation gave back, worked or dropped
    c0="$(info inline_discard_cmds)"; g0="$(info inline_discard_gave_up)"
    mark="$(dmesg_mark)"
    fill "$1b" # a fresh no-space verdict
    fallocate -p -o $((4 << 20)) -l $((8 << 20)) "$MNT/f"
    sync
    sleep 1.5
    ct_param_set inline_discard_never_give_up 0
    DC=$(($(info inline_discard_cmds) - c0))
    DG=$(($(info inline_discard_gave_up) - g0))
    LOG="$(dmesg_since "$mark")"
    ct_umount "$MNT"
}

log "1: a hole punched just after an ENOSPC"
pressure_round 1 0
[ "$DG" -ge 1 ] && [ "$DC" = 0 ] && pass "1: the worker dropped $DG range(s) and issued nothing" ||
    fail "1: gave up $DG, issued $DC"
grep -q "inline discard: dropped [0-9]* queued range(s) (no space)" <<<"$LOG" && pass "1: and said why" ||
    fail "1: no 'no space' drop in the log"

log "2: NEGATIVE CONTROL -- the worker never gives up"
pressure_round 2 1
[ "$DC" -ge 1 ] && pass "2: under the same pressure it discards ($DC) -- 1 is the give-up" ||
    fail "2: nothing discarded even when told never to give up (gave up $DG) -- 1 proves nothing"

# unmount_round <tag> <never_give_up>: five 1 MiB holes, each its own
# range, the worker held 3 s per claim; unmount once it holds the first.
# Sets SECS (the unmount's duration), LOG.
unmount_round() {
    local mark i t0
    mnt
    dd if=/dev/urandom of="$MNT/f" bs=1M count=32 conv=fsync status=none
    sync
    ct_param_set inline_discard_never_give_up "$2"
    ct_param_set inline_discard_stall_ms 3000
    mark="$(dmesg_mark)"
    for i in 0 1 2 3 4; do fallocate -p -o $(((i * 4 + 1) << 20)) -l $((1 << 20)) "$MNT/f"; done
    sync
    for i in $(seq 1 50); do
        dmesg_since "$mark" | grep -q "inline discard: claimed" && break
        sleep 0.1
    done
    dmesg_since "$mark" | grep -q "inline discard: claimed" ||
        { fail "$1 setup: the worker never started"; ct_exit; }
    t0="$(date +%s)"
    ct_umount "$MNT"
    SECS=$(($(date +%s) - t0))
    ct_param_set inline_discard_stall_ms 0
    ct_param_set inline_discard_never_give_up 0
    LOG="$(dmesg_since "$mark")"
}

log "3: unmount while the worker is mid-pass"
unmount_round 3 0
[ "$SECS" -le 6 ] && pass "3: the unmount took ${SECS}s: the worker stopped after the range in hand" ||
    fail "3: the unmount took ${SECS}s"
grep -q "inline discard: dropped [0-9]* queued range(s) (unmount)" <<<"$LOG" && pass "3: the rest was dropped, and said so" ||
    fail "3: no unmount drop in the log"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "3: fsck clean" || fail "3: fsck: $(grep -m3 '^ERR' <<<"$OUT")"

log "4: NEGATIVE CONTROL -- the worker never gives up"
unmount_round 4 1
[ "$SECS" -ge 10 ] && pass "4: the unmount waited ${SECS}s for every range -- 3's is the give-up" ||
    fail "4: the unmount took only ${SECS}s with the give-up off -- 3 proves nothing"

log "5: unmount with a queue the worker has not started"
mnt
dd if=/dev/urandom of="$MNT/f" bs=1M count=8 conv=fsync status=none
sync
ct_param_set inline_discard_delay_ms 3000
MARK="$(dmesg_mark)"
fallocate -p -o 0 -l $((4 << 20)) "$MNT/f"
sync
Q="$(info inline_discard_queued)"
[ "$Q" -ge 1 ] || { fail "5 setup: nothing queued"; ct_exit; }
ct_umount "$MNT"
ct_param_set inline_discard_delay_ms 200
dmesg_since "$MARK" | grep -q "inline discard: dropped [0-9]* queued range(s) (unmount)" &&
    pass "5: the pending queue was dropped at unmount" || fail "5: no drop at unmount in the log"
sleep 4 # past the delay the cancelled work would have run at
! dmesg_since "$MARK" | grep -qE "BUG|Oops|general protection|Busy inodes|use-after-free" &&
    pass "5: nothing ran after the unmount" || fail "5: $(dmesg_since "$MARK" | grep -m1 -E 'BUG|Oops|general protection|Busy inodes|use-after-free')"
ct_exit
