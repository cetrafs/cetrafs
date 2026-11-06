#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a cold-tree reconcile that could not read the record tries again
#
# When a peer's publish is noticed, the file's cached extent tree is
# marked cold and a reconcile on the mount's queue drops it and settles
# the mark; until then every tree read goes to the device. A reconcile
# whose allocation or record read failed settled nothing and was never
# queued again -- only a new mark queues it, and a running VM never
# reopens its disk: forced-fresh reads for the life of the open (audit
# 2026-11-05, section 3).
#
# A failed reconcile is parked with its reference and the heartbeat tick
# queues it again -- not a sleep on the queue's worker every 100 ms --
# for at most CETRAFS_COLD_RETRIES_MAX (8) tries, then it is left cold
# with a warning. Unmount drops what is parked.
#
# cold_read_fail fails the next N reconciles' record reads; a stat marks
# the tree. Asserted: (1) one failure is retried on a beat and settles
# (file_cache_reconciles moves); (2) an unreadable record is tried 1 + 8
# times and no more, a beat apart (not 10 a second), and is reported;
# (3) a new mark that runs a parked reconcile which fails again does not
# park it twice; (4) an unmount with a reconcile parked leaves no busy
# inode and no warning (the harness checks dmesg).
#
# DISCRIMINATION: proven 2026-11-05 without the retry: the counter does
# not move and the tree stays cold. With the 100 ms sleep-and-requeue,
# (2) consumes the whole knob within seconds and never gives up. With
# cetrafs_sb_cold_park() not refusing an entry already parked, (3) reads
# two entries for one inode.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/cold_read_fail ] || { skip "cold_read_fail is missing"; ct_exit; }

DEV="$(ct_dev 560 coldre)"
MNT="$(ct_mnt coldre)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2 # the retry rides the beat
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
rec() { sed -n 's/^file_cache_reconciles: //p' "$INFO"; }
echo data >"$MNT/v"
sync
stat "$MNT/v" >/dev/null
sleep 0.5
R0="$(rec)"
stat "$MNT/v" >/dev/null
sleep 0.5
[ "$(rec)" -gt "$R0" ] || { fail "setup: a stat does not reconcile this file's tree at all ($R0 -> $(rec))"; ct_exit; }

R0="$(rec)"
ct_param_set cold_read_fail 1
stat "$MNT/v" >/dev/null
sleep 6 # within three beats
LEFT="$(cat /sys/module/cetrafs/parameters/cold_read_fail)"
ct_param_set cold_read_fail 0
[ "$LEFT" = 0 ] || { fail "setup: no reconcile ran into the failure (knob still $LEFT)"; ct_exit; }
R1="$(rec)"
[ "$R1" -gt "$R0" ] && pass "a reconcile whose read failed was retried and settled ($R0 -> $R1)" ||
    fail "a reconcile whose read failed was never retried: the tree stays cold ($R0 -> $R1)"
knob() { cat /sys/module/cetrafs/parameters/cold_read_fail; }
R0="$(rec)"
MARK="$(dmesg_mark)"
ct_param_set cold_read_fail 50
stat "$MNT/v" >/dev/null
sleep 1.5
EARLY=$((50 - $(knob)))
[ "$EARLY" -ge 1 ] || { fail "setup: no reconcile ran into the failure"; ct_exit; }
[ "$EARLY" -le 2 ] && pass "an unreadable record is not re-read in a tight loop ($EARLY tries in 1.5 s)" ||
    fail "an unreadable record was tried $EARLY times in 1.5 s -- a retry loop, not a backoff"
for _ in $(seq 1 40); do
    dmesg_since "$MARK" | grep -q "after 8 tries" && break
    sleep 1
done
sleep 5 # two more beats: nothing may follow the give-up
USED=$((50 - $(knob)))
ct_param_set cold_read_fail 0
dmesg_since "$MARK" | grep -q "record still unreadable .* after 8 tries" &&
    pass "the give-up is reported" || fail "no report after the retries ran out"
[ "$USED" = 9 ] && pass "the reconcile was tried 1 + 8 times and then left alone" ||
    fail "the reconcile was tried $USED times (want 9: one run, eight retries)"
[ "$(rec)" = "$R0" ] || fail "setup: a reconcile settled although every read failed ($R0 -> $(rec))"

# a new mark while parked: the park's work is not pending, so the mark
# runs it again; when that run fails too it must not park the inode a
# second time (a corrupt list and one leaked reference). A tick inside
# the window would take the entry itself, so a round counts only when
# exactly one run -- the mark's -- happened in it.
parked() { sed -n 's/^file_cache_cold_parked: //p' "$INFO"; }
[ -n "$(parked)" ] || { fail "setup: procfs info has no file_cache_cold_parked"; ct_exit; }
ct_param_set cold_read_fail 50
stat "$MNT/v" >/dev/null
DONE=
for _ in 1 2 3 4 5; do
    for _ in $(seq 1 30); do [ "$(parked)" = 1 ] && break; sleep 0.1; done
    [ "$(parked)" = 1 ] || continue
    K0="$(knob)"
    stat "$MNT/v" >/dev/null
    sleep 0.3
    N="$(parked)"
    [ $((K0 - $(knob))) = 1 ] || continue
    DONE=1
    break
done
[ -n "$DONE" ] || { fail "setup: never ran a fresh mark against a parked reconcile in isolation"; ct_exit; }
[ "$N" = 1 ] && pass "a failed run of a parked inode does not park it again (parked: $N)" ||
    fail "a failed run of a parked inode parked it again (parked: $N, want 1)"
ct_param_set cold_read_fail 0

# unmount while one is parked: its reference must be dropped, not leaked
ct_param_set cold_read_fail 50
stat "$MNT/v" >/dev/null
sleep 0.5
[ "$(knob)" -lt 50 ] || { fail "setup: the reconcile did not fail before the unmount"; ct_exit; }
ct_umount "$MNT"
ct_param_set cold_read_fail 0
pass "an unmount with a reconcile parked completed (busy inodes are checked from dmesg)"
ct_exit
