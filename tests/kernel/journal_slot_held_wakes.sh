#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a writer waiting for a journal slot is woken when the last one becomes held
#
# A journaled write that finds every slot busy waits on slot_wq for "a
# slot is free OR every slot is held" -- the second half is what turns a
# journal full of entries kept by failed writes into an -EIO instead of a
# hang. cetrafs_journal_hold_slot() makes that half true and woke nobody;
# only the two paths that free a slot did. So a writer waiting when the
# last in-flight slot became held (its target write failed) slept for
# ever, uninterruptibly, holding its buffer's update lock (audit
# 2026-11-05, N2).
#
# Staged with one slot (journal_slots_max=1): writer 1 takes it and stalls
# between its entry and its target write (journal_target_stall_ms); writer
# 2, in another directory, waits for a slot; writer 1's target write then
# fails (journal_fail_target_write) and the slot is held. Writer 2 must
# come back with EIO promptly.
#
# The control is recoverable, not a wedged box: a later write of writer
# 1's block takes the held slot over, and its ordinary exit wakes the
# waiter.
#
# DISCRIMINATION: proven 2026-11-05 with the wake removed from
# cetrafs_journal_hold_slot() (knobs kept): writer 2 is still asleep in D
# state 5 s after writer 1 failed, and finishes only when the rescue write
# frees the slot.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_slots_max journal_target_stall_ms journal_fail_target_write; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

DEV="$(ct_dev 560 jshw)"
MNT="$(ct_mnt jshw)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_param_set journal_slots_max 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set journal_slots_max 0
mkdir "$MNT/d1" "$MNT/d2"
sync
: >"$MNT/d1/warm" && : >"$MNT/d2/warm" || { fail "setup: a journaled create failed before the staging"; ct_exit; }

R1="$(ct_tmp jshw-r1)"
R2="$(ct_tmp jshw-r2)"
ct_param_set journal_target_stall_ms 3000
ct_param_set journal_fail_target_write 1
( : >"$MNT/d1/a" 2>/dev/null && echo ok >"$R1" || echo err >"$R1" ) &
W1=$!
sleep 0.7
( : >"$MNT/d2/b" 2>/dev/null && echo ok >"$R2" || echo err >"$R2" ) &
W2=$!
sleep 0.7
ST="$(ps -o stat= -p "$W2" 2>/dev/null | tr -d ' ' || true)"
[ -s "$R2" ] && { fail "setup: writer 2 finished ($(cat "$R2")) before writer 1 released its slot -- nothing waited"; wait; ct_exit; }
log "writer 2 while writer 1 holds the only slot: state $ST"
wait "$W1" || true
ct_param_set journal_fail_target_write 0
ct_param_set journal_target_stall_ms 0
[ "$(cat "$R1")" = err ] && pass "setup: writer 1's target write failed (its slot is now held)" ||
    { fail "setup: writer 1 did not fail ($(cat "$R1")) -- no slot was held"; wait; ct_exit; }

GOT=""
for _ in $(seq 1 50); do
    [ -s "$R2" ] && { GOT=1; break; }
    sleep 0.1
done
if [ -n "$GOT" ]; then
    pass "writer 2 was woken when the last slot became held"
    [ "$(cat "$R2")" = err ] && pass "and got the error the full journal means" ||
        fail "writer 2 reported $(cat "$R2"), not an error, with every slot held"
else
    fail "writer 2 still waits 5 s after the last slot became held (state $(ps -o stat= -p "$W2" 2>/dev/null || echo ?)) -- nothing woke it"
    log "rescuing: a write of writer 1's block takes the held slot over"
    : >"$MNT/d1/rescue" 2>/dev/null || true
fi
wait "$W2" || true
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
