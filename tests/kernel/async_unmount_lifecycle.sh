#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# unmount while each async source is mid-flight: everything drains before teardown, nothing runs after
#
# BUG-CLASSES.md class 18. The 0.9.3 field Oops was one instance -- a
# cold-tree reconcile on the system workqueue outlived the mount
# (cold_work_unmount.sh) -- and the class is every asynchronous source
# the module has. Each case here holds one source open with its stall
# knob, unmounts while it is held, then waits past the point where the
# held work would resume. The harness fails the suite on any Oops, BUG,
# WARNING or "Busy inodes after unmount" in dmesg, which is what an
# undrained source produces; each case also requires the unmount to
# have WAITED for the source (it returned only after the hold).
#
#   1. auto-defrag worker mid-move (defrag_step_delay_ms), file deleted
#   2. scrub holding its verdict (scrub_verdict_stall_ms)
#   3. heartbeat maintenance mid-pass (hb_maint_delay_ms) with a deferred
#      lock clear queued for a deleted file
#   4. a mount stopped by a fatal error (stop_work queued) unmounted at once
#
# A NEW async source belongs here as a case before it ships (class 18's
# process); source_invariants.sh refuses one that names no drain.
#
# DISCRIMINATION: each case asserts its source was in flight at umount
# (a worker in that function, or its log line); drop a drain from
# cetrafs_free_sb_info() and the case's unmount returns early and the
# work runs on freed state.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in defrag_step_delay_ms scrub_verdict_stall_ms hb_maint_delay_ms lock_clear_fail_once nslock_release_fail; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

in_flight() { grep -l "$1" /proc/[0-9]*/stack 2>/dev/null | head -1; }
# umount_timed <mnt>: unmount, print the milliseconds it took
umount_timed() {
    local t0
    t0="$(date +%s%N)"
    ct_umount "$1"
    echo $((($(date +%s%N) - t0) / 1000000))
}

# ---------------------------------------------------------------- 1
log "1: unmount while the auto-defrag worker is mid-move"
DEV="$(ct_dev 560 lc1)"
MNT="$(ct_mnt lc1)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
for i in $(seq 0 15); do
    dd if=/dev/urandom of="$MNT/frag" bs=4096 seek="$i" count=1 conv=notrunc status=none
    printf x >"$MNT/filler$i"
done
sync
ct_param_set defrag_step_delay_ms 1500
ct_param_set auto_defrag 1
: >>"$MNT/frag" # a write-open + close triggers the worker
wait_for 10 '[ -n "$(in_flight cetrafs_defrag_worker)" ]' ||
    { fail "1: setup: the defrag worker never started"; ct_exit; }
rm "$MNT/frag"
pass "1: setup: defrag is moving the file, which is now deleted"
MS="$(umount_timed "$MNT")"
ct_param_set auto_defrag 0
ct_param_set defrag_step_delay_ms 0
[ -z "$(in_flight cetrafs_defrag_worker)" ] && pass "1: unmount ($MS ms) left no defrag worker running" ||
    fail "1: a defrag worker is still running after the unmount returned"
sleep 3
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "1: fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" ||
    pass "1: fsck clean"

# ---------------------------------------------------------------- 2
log "2: unmount while the scrub holds its verdict"
DEV="$(ct_dev 560 lc2)"
MNT="$(ct_mnt lc2)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_param_set scrub_verdict_stall_ms 6000
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
echo data >"$MNT/f"
wait_for 20 "dmesg_since '$MARK' | grep -q 'scrub: holding the verdict'" ||
    { fail "2: setup: the scrub never reached its verdict"; ct_exit; }
pass "2: setup: the scrub is holding a verdict"
MS="$(umount_timed "$MNT")"
ct_param_set scrub_verdict_stall_ms 0
[ -z "$(in_flight cetrafs_scrub)" ] && pass "2: unmount ($MS ms) left no scrub running" ||
    fail "2: a scrub cycle is still running after the unmount returned"
sleep 2
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "2: fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" ||
    pass "2: fsck clean"

# ---------------------------------------------------------------- 3
log "3: unmount during heartbeat maintenance, with a deferred lock clear of a deleted file"
DEV="$(ct_dev 560 lc3)"
MNT="$(ct_mnt lc3)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2 # read at mount
ct_mount "$DEV" "$MNT"
ct_param_set lock_clear_fail_once 1
echo data >"$MNT/gone" # its close fails to clear the lock: queued for the heartbeat
rm "$MNT/gone"
ct_param_set hb_maint_delay_ms 4000
wait_for 15 '[ -n "$(in_flight cetrafs_heartbeat)" ]' ||
    { fail "3: setup: no heartbeat maintenance pass in flight"; ct_exit; }
pass "3: setup: maintenance is mid-pass with a lock clear queued"
MS="$(umount_timed "$MNT")"
ct_param_set hb_maint_delay_ms 0
ct_param_set lock_clear_fail_once 0
[ -z "$(in_flight cetrafs_heartbeat)" ] && pass "3: unmount ($MS ms) left no heartbeat work running" ||
    fail "3: heartbeat work is still running after the unmount returned"
sleep 3

# ---------------------------------------------------------------- 4
log "4: unmount at once after a fatal stop queued its work"
DEV="$(ct_dev 560 lc4)"
MNT="$(ct_mnt lc4)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")"
mkdir "$MNT/d"
sync
ct_param_set nslock_release_fail 1
: >"$MNT/d/f" 2>/dev/null || true # a lost directory publish stops the mount
ct_param_set nslock_release_fail 0
[ "$(sed -n 's/^stopped: //p' "$PROC/info")" = error ] && pass "4: setup: the mount stopped" ||
    { fail "4: setup: the mount did not stop"; ct_exit; }
ct_umount "$MNT" || umount -l "$MNT"
pass "4: unmounted"
sleep 2
ct_exit
