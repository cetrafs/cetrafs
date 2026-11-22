#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocator out of space waits for a running drain before it says ENOSPC
#
# Frees queued for a Zone Group this node owns are space it does not
# have until a drain applies them. The allocator's drains used a
# trylock: when the heartbeat's drain held the mutex, "one is running"
# read as "nothing queued", and a write failed ENOSPC with the space
# sitting in the queue (audit 2026-11-22 N-31; with the queue-full
# backoff and the scrub's abort, one of three ways freed space stopped
# coming back). Out of space, the allocator now waits for the running
# drain (killably) and looks again.
#
# Staged on one node, one Zone Group (nothing else to claim): a 16 MiB
# file, then the volume filled; the file deleted with pf_force_foreign,
# so its frees are queued, not applied, and every drain held off. Then a
# heartbeat drain is let run and held once it has the mutex
# (pf_drain_hold_ms, 30 s); once it is holding, a write 4 MiB larger than what is free
# must succeed.
#
# DISCRIMINATION: the control, in-suite -- alloc_drain_nowait=1, the old
# trylock: the write fails ENOSPC.
# ct-timeout: 240
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in alloc_drain_nowait pf_drain_hold_ms pf_force_foreign hb_drain_off; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt awrd)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_drain_nowait 0
ct_param_set pf_drain_hold_ms 0
ct_param_set pf_drain_min_ms 600000
ct_param_set hb_drain_off 0

# round <nowait 0|1> -> "<write> <queued blocks> <drain waits>"
round() {
    local dev proc w=fail q0 q1 w0 need a0 a1 qd
    dev="$(ct_loop "$(ct_image 560 "awrd$1")")"
    ct_mkfs "$dev" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "hb_interval_secs=5" >"$proc/controls"
    dd if=/dev/urandom of="$MNT/b" bs=1M count=16 conv=fsync status=none
    dd if=/dev/zero of="$MNT/fill" bs=1M conv=fsync status=none 2>/dev/null || true
    sync
    echo 1 >$P/hb_drain_off
    echo 1 >$P/pf_force_foreign
    q0="$(sed -n 's/^pf_drain_blocks: //p' "$proc/info")"
    a0="$(stat -f -c %a "$MNT")"
    rm -f "$MNT/b"
    sync
    echo 2 >/proc/sys/vm/drop_caches
    echo 0 >$P/pf_force_foreign
    # More than is free now, less than the queued 16 MiB: only the
    # queued frees can make room for it.
    a1="$(stat -f -c %a "$MNT")"
    need=$((a1 + 1024))
    echo "$1" >$P/alloc_drain_nowait
    echo 30000 >$P/pf_drain_hold_ms
    w0="$(sed -n 's/^alloc_drain_waits: //p' "$proc/info")"
    echo 0 >$P/hb_drain_off
    # the next beat's drain has the mutex, and holds it
    wait_for 20 'grep -q "^pf_drain_holding: 1" "$proc/info"' || log "round $1: no drain began its hold" >&2
    sleep 1
    qd=$(($(sed -n 's/^pf_drain_blocks: //p' "$proc/info") - q0))
    t0=$(date +%s); dd if=/dev/urandom of="$MNT/c" bs=4k count="$need" conv=fsync status=none 2>/dev/null && w=ok; log "round $1: the write took $(($(date +%s) - t0)) s" >&2
    echo 0 >$P/pf_drain_hold_ms
    echo 0 >$P/alloc_drain_nowait
    q1="$(sed -n 's/^pf_drain_blocks: //p' "$proc/info")"
    log "round $1: free after fill $a0, after rm $a1, need $need, drained before the write $qd" >&2
    echo "$w $((q1 - q0)) $(($(sed -n 's/^alloc_drain_waits: //p' "$proc/info") - w0))"
    ct_umount "$MNT"
}

read -r CW CQ CWT <<<"$(round 1)"
log "control (trylock): write $CW, drained $CQ blocks, drain waits $CWT"
read -r W Q WT <<<"$(round 0)"
log "fixed: write $W, drained $Q blocks, drain waits $WT"
[ "$CW" = fail ] && pass "control: with the trylock, the write failed ENOSPC while a drain ran" ||
    fail "control: the write succeeded with the trylock -- the hazard did not reproduce"
[ "$W" = ok ] && [ "$WT" -ge 1 ] && pass "the write waited for the running drain ($WT wait(s)) and found its space" ||
    fail "the write: $W, drain waits $WT, drained $Q"
ct_exit
