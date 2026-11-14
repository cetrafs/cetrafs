#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocating or freeing thread proceeds while an ENOSPC recount's write is out
#
# The recount reads a Block Group's bitmap and writes the count into its
# descriptor. It held the node-wide allocation mutex across that write,
# so every allocating or freeing thread on the node waited one device
# round trip. It now releases the mutex once the count is taken into a
# flight (cetrafs_bg_recount_after_enospc()): accruals made while the
# write is out stay in the delta, and the epoch move keeps them.
#
# Staged: Block Group 0 holds a 4 MB file. A forced ENOSPC
# (alloc_force_enospc_once) makes a second write recount Block Group 0,
# held after its write (reconcile_written_stall_ms). While it is held, the
# first file is removed: its 1000 blocks are freed into Block Group 0's
# accrued delta while the recount's flight is open. The free must show up
# in the free count during the hold. (The removal itself then waits in
# its evict for the flush of that group's count -- the one-writer rule --
# so the probe reads the count, not the removal's return.)
#
#  1. the freed blocks show in the free count during the hold;
#  2. the second write's recount ran and the group is intact: fsck clean,
#     and the free count after the remount is the one fsck counts;
#  3. control (recount_hold_alloc=1, the old hold across the write): the
#     removal waits the whole hold;
#  4. control (recount_inflight_drop=1): the accrual made during the
#     flight is dropped at the epoch move, and fsck reports the group's
#     count 1000 blocks short of its bitmap -- the exactness check can
#     fail.
#
# Knobs that do not exist on this build are skipped with a reason; the
# test of the fix needs none of them.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in reconcile_written_stall_ms alloc_force_enospc_once reconcile_flight_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
HAVE_HOLD=0
HAVE_DROP=0
[ -w /sys/module/cetrafs/parameters/recount_hold_alloc ] && HAVE_HOLD=1
[ -w /sys/module/cetrafs/parameters/recount_inflight_drop ] && HAVE_DROP=1

IMG="$(ct_image 1200 recconc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt recconc)"
ct_track mnt "$MNT"
ct_param_set reconcile_written_stall_ms 0
ct_param_set alloc_force_enospc_once 0
ct_param_set reconcile_flight_off 0
ct_param_set alloc_run_blocks 0
ct_param_set hb_interval_secs 30 # no tick flushes inside the hold
ct_param_set scrub 0
ct_param_set auto_defrag 0
[ "$HAVE_HOLD" = 1 ] && ct_param_set recount_hold_alloc 0
[ "$HAVE_DROP" = 1 ] && ct_param_set recount_inflight_drop 0

HOLD_MS=3000
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# probe_count_moves <from> <to> <t0-ns>: echoes the ms until the free count
# reaches <to> (moving toward it from <from>), or HOLD_MS+1 if it never does
probe_count_moves() {
    local ms=$((HOLD_MS + 1)) i now
    for i in $(seq 1 $((HOLD_MS / 20))); do
        now="$(info free_data_blocks)"
        if { [ "$2" -gt "$1" ] && [ "$now" -ge "$2" ]; } || { [ "$2" -lt "$1" ] && [ "$now" -le "$2" ]; }; then
            ms=$((($(date +%s%N) - $3) / 1000000))
            break
        fi
        sleep 0.02
    done
    echo "$ms"
}

# <tag> <hold: 0|1>: sets PROBE_MS (the removal's wall time during the
# hold), RECOUNTS (recounts of Block Group 0), FSCK (fsck's verdict line)
run() {
    local MARK G T0 T1 hold_seen
    ct_mkfs "$DEV" -z 2 -b 512 -J 2 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/old" bs=4096 count=1000 status=none
    touch "$MNT/g" "$MNT/n" # created now: a create during the removal's evict would wait on its inode number
    sync -f "$MNT"
    [ "$(stat -c %s "$MNT/old")" = 4096000 ] || { fail "$1: setup: the file is not 1000 blocks"; ct_exit; }

    MARK="$(dmesg_mark)"
    ct_param_set reconcile_written_stall_ms "$HOLD_MS"
    ct_param_set alloc_force_enospc_once 1
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, b"G" * 4096, 0)
os.fsync(fd)
' "$MNT/g" &
    G=$!
    hold_seen=0
    for _ in $(seq 1 100); do
        dmesg_since "$MARK" | grep -q "reconcile: BG 0 written, pausing" && { hold_seen=1; break; }
        sleep 0.05
    done
    [ "$hold_seen" = 1 ] || { fail "$1: setup: no recount of Block Group 0 was held: $(dmesg_since "$MARK" | tail -5 | tr '\n' '|')"; kill "$G" 2>/dev/null || true; ct_exit; }
    ct_param_set alloc_force_enospc_once 0

    # the free, then an allocation of 1000 blocks, both during the hold
    BEFORE="$(info free_data_blocks)"
    T0="$(date +%s%N)"
    rm -f "$MNT/old" &
    RM=$!
    PROBE_MS="$(probe_count_moves "$BEFORE" $((BEFORE + 1000)) "$T0")"
    AFTER_RM="$(info free_data_blocks)"
    ALLOC_MS=0
    if [ "${ALLOC_PROBE:-1}" = 1 ]; then
        # an allocation of the same size: the two cancel, so the count
        # ends where the recount left it -- which is why the drop control
        # runs the free alone (its loss must not cancel out)
        T0="$(date +%s%N)"
        fallocate -l 4096000 "$MNT/n" &
        FA=$!
        ALLOC_MS="$(probe_count_moves "$AFTER_RM" $((AFTER_RM - 1000)) "$T0")"
        wait "$FA" || fail "$1: the allocation failed"
    fi
    wait "$RM" || fail "$1: the removal failed"
    wait "$G" || fail "$1: the write that recounted failed"
    ct_param_set reconcile_written_stall_ms 0
    RECOUNTS="$(dmesg_since "$MARK" | grep -c "BG 0 reported free space but its bitmap is full" || true)"
    [ "$RECOUNTS" -ge 1 ] || fail "$1: setup: the write did not recount Block Group 0"

    ct_umount "$MNT"
    FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
    if ct_fsck "$DEV" >/dev/null 2>&1; then
        FSCK=clean
    else
        FSCK="$(grep -m2 'ERR' <<<"$FSCK_OUT" | tr '\n' ' ')"
    fi
    log "$1: 1000 freed blocks visible after ${PROBE_MS} ms, allocation after ${ALLOC_MS} ms, of a ${HOLD_MS} ms hold; $RECOUNTS recount(s); fsck: $FSCK"
}

# ------------------------------------------------------------------ 3
if [ "$HAVE_HOLD" = 1 ]; then
    log "3: control -- the old hold across the descriptor write"
    ct_param_set recount_hold_alloc 1
    run hold
    ct_param_set recount_hold_alloc 0
    [ "$PROBE_MS" -ge $((HOLD_MS - 500)) ] && pass "control: the freed blocks showed only after the hold ($PROBE_MS ms)" ||
        fail "control: the freed blocks showed after $PROBE_MS ms -- the hold does not stop them, so the suite cannot tell the two apart"
else
    skip "control 3: recount_hold_alloc is missing"
fi

# ------------------------------------------------------------------ 1-2
log "1: a removal during the recount's write"
run fix
[ "$PROBE_MS" -lt $((HOLD_MS / 2)) ] && pass "1: the freed blocks showed during the recount's write ($PROBE_MS ms)" ||
    fail "1: the freed blocks waited $PROBE_MS ms for the recount's write"
[ "$ALLOC_MS" -lt $((HOLD_MS / 2)) ] && pass "1: an allocation landed during the recount's write ($ALLOC_MS ms)" ||
    fail "1: the allocation waited $ALLOC_MS ms for the recount's write"
[ "$FSCK" = clean ] && pass "2: fsck clean after the recount and the removal" ||
    fail "2: fsck: $FSCK"

# ------------------------------------------------------------------ 4
if [ "$HAVE_DROP" = 1 ]; then
    log "4: control -- the accrual made during the flight is dropped"
    ct_param_set recount_inflight_drop 1
    ALLOC_PROBE=0 run drop
    ct_param_set recount_inflight_drop 0
    case "$FSCK" in
    clean) fail "control: fsck is clean with the accrual dropped -- the exactness check cannot see it" ;;
    *) pass "control: fsck reports the dropped accrual" ;;
    esac
else
    skip "control 4: recount_inflight_drop is missing"
fi
ct_exit
