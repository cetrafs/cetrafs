#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# A FULL pending-free queue must not cost a device scan per extent.
#
# A free aimed at a ZG this node does not own is appended to that ZG's
# queue, and the append scans every slot: qblocks * regions CAS
# operations, each a device round trip. When the queue is full that scan
# is paid per extent and finds nothing, and the leak diagnostic reads
# two more records off the device and prints a line. Deleting one large
# VM image is tens of thousands of extents, so the filesystem appears to
# stop -- the futile scanning, not the leak itself, is what the operator
# feels.
#
# So a full queue is remembered for pf_full_backoff_ms, and the verbose
# diagnostic runs once per burst instead of once per extent.
#
# Reaching that path on one node needs three test-only knobs:
#   pf_force_foreign     -- route frees through the foreign queue (a
#                           single-node mount owns its ZGs otherwise)
#   pf_force_queue_full  -- the queue is full, and its owner is ALIVE,
#                           which is the production case; a stale owner
#                           gets its ZG reclaimed and the free goes
#                           direct, so the drop path never runs
#   pf_full_backoff_ms=0 -- the negative control
# set -euo pipefail, and the BASH_SOURCE form, like every other suite.
# Without -e a failed mkfs or mount here was ignored and the assertions
# below ran against nothing -- the vacuous pass tests/README.md exists
# to prevent.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
suite "pending-free backoff when the queue is full"

IMG="$(ct_image 1200 pfbackoff)"
LOOP="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfbackoff)"
INFO="/proc/fs/cetrafs/$(basename "$LOOP")/info"
ct_mkfs "$LOOP" -f >/dev/null
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"

ct_param_set pf_force_foreign 1
ct_param_set pf_force_queue_full 1

counter() { awk -v k="^$1:" '$0 ~ k {print $2}' "$INFO"; }

# Returns: "<drops> <scans> <verbose-lines>" for one delete burst.
burst() { # <name>
    local name="$1" s0 d0 s1 d1 mark i
    # MANY FILES, not one big one: 64 MiB written to a fresh volume
    # lands in a single contiguous extent, so the delete produces one
    # free and the whole comparison measures nothing. Each file is its
    # own inode with its own extent, so the drop count is the file
    # count and does not depend on how the allocator happened to lay
    # the volume out.
    mkdir -p "$MNT/$name"
    for i in $(seq 1 200); do
        dd if=/dev/zero of="$MNT/$name/f$i" bs=64k count=1 status=none
    done
    sync
    # Let any backoff window left over from setting the volume up
    # expire, so this burst starts from a clean state and its FIRST
    # drop is expected to scan once and log once. Without this the
    # measurement can be a trivial zero, and a build that stopped
    # warning altogether would pass.
    sleep 1.5
    s0="$(counter pf_full_scans)"; d0="$(counter pf_drop_runs)"
    mark="$(dmesg_mark)"
    rm -rf "$MNT/$name"
    # The blocks are freed at EVICTION, not at unlink: without this the
    # delete frees nothing and the test measures an empty burst.
    sync; echo 3 >/proc/sys/vm/drop_caches; sync
    s1="$(counter pf_full_scans)"; d1="$(counter pf_drop_runs)"
    echo "$((d1 - d0)) $((s1 - s0)) $(dmesg_since "$mark" | grep -c 'queue full, DROPPING' || true)"
}

ct_param_set pf_full_backoff_ms 1000
read -r ON_DROPS ON_SCANS ON_LOGS <<<"$(burst on)"
log "backoff on:  $ON_DROPS drop(s), $ON_SCANS scan(s), $ON_LOGS verbose line(s)"

ct_param_set pf_full_backoff_ms 0
read -r OFF_DROPS OFF_SCANS OFF_LOGS <<<"$(burst off)"
log "backoff off: $OFF_DROPS drop(s), $OFF_SCANS scan(s), $OFF_LOGS verbose line(s)"

# Vacuity gates first: everything below is meaningless without drops.
if [ "${ON_DROPS:-0}" -lt 20 ] || [ "${OFF_DROPS:-0}" -lt 20 ]; then
    fail "only $ON_DROPS/$OFF_DROPS drops -- the delete did not reach the drop path"
    ct_umount "$MNT"
    ct_exit
fi

if [ "$ON_SCANS" -ge 1 ] && [ "$ON_SCANS" -le 5 ]; then
    pass "a known-full queue is not rescanned: $ON_SCANS scan(s) for $ON_DROPS drop(s)"
elif [ "$ON_SCANS" -lt 1 ]; then
    fail "$ON_DROPS drops and not one scan -- the queue was never actually looked at"
else
    fail "$ON_SCANS scans for $ON_DROPS drops -- a known-full queue is still rescanned per extent"
fi

[ "$OFF_SCANS" -ge "$((OFF_DROPS / 2))" ] ||
    fail "control: only $OFF_SCANS scans for $OFF_DROPS drops with the backoff disabled -- something else is suppressing them, so the comparison proves nothing"
[ "$OFF_SCANS" -ge "$((OFF_DROPS / 2))" ] &&
    pass "negative control: disabling the backoff restores the per-extent scan ($OFF_SCANS vs $ON_SCANS)"

# Once per burst, and at least once: aggregating the warning away
# entirely would leave an operator with a silently leaking volume.
if [ "$ON_LOGS" -ge 1 ] && [ "$ON_LOGS" -le 2 ]; then
    pass "the verbose leak diagnostic runs once per burst ($ON_LOGS line(s) for $ON_DROPS drops)"
elif [ "$ON_LOGS" -lt 1 ]; then
    fail "the burst dropped $ON_DROPS runs and logged NOTHING -- a leaking volume would be silent"
else
    fail "$ON_LOGS verbose LEAK lines for $ON_DROPS drops -- the diagnostic is not aggregated"
fi

[ "$OFF_LOGS" -gt "$ON_LOGS" ] ||
    fail "control: $OFF_LOGS verbose lines with the backoff off vs $ON_LOGS with it on"
[ "$OFF_LOGS" -gt "$ON_LOGS" ] &&
    pass "negative control: without the backoff every drop logs ($OFF_LOGS vs $ON_LOGS)"

# ---- the DRAIN must cost what the queue HOLDS, not what it can hold --
#
# The drain runs on every heartbeat tick for every owned ZG and reads
# queue blocks uncached. Scanning the whole queue every tick is the
# per-tick whole-table sweep invariant 5 forbids: when the queue grew to
# hold a large delete, that sweep starved the rest of the tick and the
# stale-peer journal sweep stopped happening at all.
ct_param_set pf_force_foreign 0
ct_param_set pf_force_queue_full 0

QBLOCKS="$(grep -oP '#define CETRAFS_PENDING_FREE_BLOCKS_PER_ZG\s+\K[0-9]+' "$ROOT/include/cetrafs.h")"
EMPTY_RUN="$(grep -oP '#define CETRAFS_PF_DRAIN_EMPTY_RUN\s+\K[0-9]+' "$ROOT/include/cetrafs.h")"
ZGS_OWNED="$(awk '/^zg_owned:/{print $2}' "$INFO")"
[ -n "$ZGS_OWNED" ] && [ "$ZGS_OWNED" -gt 0 ] || ZGS_OWNED=1

D0="$(counter pf_drains)"; B0="$(counter pf_drain_blocks)"
# Idle across at least one heartbeat tick, with an empty queue.
sleep "$(( $(cat /sys/module/cetrafs/parameters/hb_interval_secs 2>/dev/null || echo 15) + 3 ))"
D1="$(counter pf_drains)"; B1="$(counter pf_drain_blocks)"
DRAINS=$((D1 - D0)); BLOCKS=$((B1 - B0))
log "idle ticks: $DRAINS drain pass(es) read $BLOCKS queue block(s) (queue is $QBLOCKS blocks/ZG)"

if [ "$DRAINS" -lt 1 ]; then
    fail "no drain pass ran in a whole tick -- nothing was measured"
else
    # Per pass, per owned ZG: the empty-run terminator, and nothing like
    # the full queue.
    BUDGET=$(( DRAINS * ZGS_OWNED * (EMPTY_RUN + 1) ))
    [ "$BLOCKS" -le "$BUDGET" ] &&
        pass "an empty queue costs $BLOCKS block read(s) over $DRAINS pass(es), not $(( DRAINS * ZGS_OWNED * QBLOCKS ))" ||
        fail "an empty queue cost $BLOCKS block reads over $DRAINS pass(es) -- budget was $BUDGET; the drain is scanning capacity, not occupancy"
fi

ct_umount "$MNT"
ct_exit
