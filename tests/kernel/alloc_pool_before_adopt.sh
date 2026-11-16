#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocator tries the pool before waiting for a dead peer's Zone Group
#
# When every group this node owns is full and the only Zone Group left
# belongs to a dead peer, the allocator waits for the heartbeat to take
# it over: a fence, a journal replay and a recount, up to 3 x stale +
# 60 s, with the writer's inode_lock and invalidate_lock held. It did
# that BEFORE trying the pool, where a free Block Group is claimed in one
# CAS (audit 2026-11-15 L-23). And an O_DIRECT completion converts in a
# workqueue, where no kill can end that wait: the write's completion,
# and truncate and fsync behind it, waited with nothing to stop it
# (BM-40).
#
#   P. a free pool Block Group exists: a write takes it at once;
#   K. no pool: an async O_DIRECT write whose conversion needs a tree
#      block completes at once, failed, instead of waiting.
#
# The takeover is held 8 s (zg_steal_stall_ms) in both.
# DISCRIMINATION: alloc_adopt_first=1 -- P waits out the takeover;
# alloc_adopt_worker_waits=1 -- K's completion waits it out.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"
AIO="$(ct_helper dio_aio)"
MNT="$(ct_mnt adoptfirst)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set bg_release_off 1
ct_param_set alloc_adopt_first 0
ct_param_set alloc_adopt_worker_waits 0
ct_param_set zg_steal_stall_ms 0
set_stale_window "$TEST_STALE_SECS"
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
ms() { awk -v a="$1" -v b="$(date +%s%N)" 'BEGIN { printf "%d", (b - a) / 1000000 }'; }

# <tag> <P|K> -> DEV, OWNED, OTHER; mounted, OTHER a dead peer's, owned full
stage() {
    local info b pool
    DEV="$(ct_dev 1200 "adopt$1")"
    ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    info="$(cat "$(ct_procdir "$DEV")/info")"
    OWNED="$(sed -n 's/.*zg \([0-9]*\): owner=[0-9]* (this node).*/\1/p' <<<"$info")"
    OTHER=$((1 - OWNED))
    if [ "$2" = K ]; then
        # Four extents, the inline slots full: [0] [10..29 preallocated] [40] [50].
        dd if=/dev/urandom of="$MNT/f" bs=4096 count=1 conv=notrunc status=none
        fallocate -o $((10 * 4096)) -l $((20 * 4096)) "$MNT/f"
        dd if=/dev/urandom of="$MNT/f" bs=4096 seek=40 count=1 conv=notrunc status=none
        dd if=/dev/urandom of="$MNT/f" bs=4096 seek=50 count=1 conv=notrunc status=none
        sync
    fi
    ct_umount "$MNT"
    for b in $(ct_bgs_of_zg "$DEV" "$OWNED"); do
        "$BG_POKE" "$DEV" "$b" 0 sync-zg >/dev/null
        "$BG_POKE" "$DEV" "$b" 0 fill-bitmap >/dev/null
    done
    if [ "$2" = P ]; then
        pool="$(ct_bgs_of_zg "$DEV" "$OTHER" | head -1)"
        "$BG_POKE" "$DEV" "$pool" --owner 65535 >/dev/null
    fi
    "$ZG_POKE" "$DEV" "$OTHER" 1 >/dev/null
    poke_dead_peer "$DEV" 1 aa
    blockdev --flushbufs "$DEV"
    ct_mount "$DEV" "$MNT"
    wait_out_stale_window
}

# <tag> <adopt_first 0|1> -> RES
round_p() {
    local t0 rc=0 mark
    stage "$1" P
    echo "$2" >/sys/module/cetrafs/parameters/alloc_adopt_first
    echo 8000 >/sys/module/cetrafs/parameters/zg_steal_stall_ms
    mark="$(dmesg_mark)"
    t0="$(date +%s%N)"
    dd if=/dev/urandom of="$MNT/w" bs=64k count=4 conv=fsync status=none || rc=$?
    RES="ms=$(ms "$t0") rc=$rc"
    dmesg_since "$mark" | grep -q "claimed free BG" && RES="$RES pool=yes" || RES="$RES pool=no"
    echo 0 >/sys/module/cetrafs/parameters/alloc_adopt_first
    echo 0 >/sys/module/cetrafs/parameters/zg_steal_stall_ms
    sleep 9 # let a held takeover finish before the unmount
    ct_umount "$MNT"
}

# <tag> <worker_waits 0|1> -> RES
round_k() {
    stage "$1" K
    echo "$2" >/sys/module/cetrafs/parameters/alloc_adopt_worker_waits
    echo 8000 >/sys/module/cetrafs/parameters/zg_steal_stall_ms
    RES="$("$AIO" once "$MNT/f" $((20 * 4096)) 4096)"
    echo 0 >/sys/module/cetrafs/parameters/alloc_adopt_worker_waits
    echo 0 >/sys/module/cetrafs/parameters/zg_steal_stall_ms
    sleep 9
    ct_umount "$MNT"
}

round_p p 0
P="$RES"
log "P: $P"
round_p pc 1
PC="$RES"
log "P control (adoption first): $PC"
round_k k 0
K="$RES"
log "K: $K"
round_k kc 1
KC="$RES"
log "K control (the workqueue waits): $KC"

[ "$(field rc "$P")" = 0 ] && [ "$(field pool "$P")" = yes ] && [ "$(field ms "$P")" -lt 4000 ] &&
    pass "P: the write took a pool Block Group without waiting for the takeover ($P)" || fail "P: $P"
[ "$(field ms "$PC")" -ge 5000 ] &&
    pass "P control: as before, the write waited out the takeover first ($PC)" ||
    fail "P control: no wait -- the suite does not reach the adoption: $PC"
[ "$(field ms "$K")" -lt 4000 ] && [ "$(field res "$K")" -lt 0 ] &&
    pass "K: the completion did not wait for the takeover in its workqueue, and failed ($K)" || fail "K: $K"
[ "$(field ms "$KC")" -ge 5000 ] &&
    pass "K control: as before, the completion waited out the takeover ($KC)" ||
    fail "K control: no wait -- the conversion did not need the dead peer's group: $KC"
ct_exit
