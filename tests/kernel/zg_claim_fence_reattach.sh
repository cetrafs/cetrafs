#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a zone group owner that came back during its takeover leaves the claim alone, not failed
#
# A Zone Group claim judges the owner stale, fences it, and replays its
# journal. When the owner re-attaches in between, the fence answers
# -EBUSY ("held by a live node after all"), and so does the replay once
# it has the journal (it checks the row again). Every other fence caller
# maps that to "leave it", but the claim returned both as errors: the
# mount failed over a peer that was simply alive, and so did a write
# that needed a group (N-16).
#
# Staged on a one-group volume: ZG 0 belongs to node 1, planted and left
# stale; node 1's row beats again while the mount's claim is held --
#   A. before the fence (fence_stall_ms), under the claim mutex;
#   B. after the fence, before the replay (reclaim_stall_after_fence_ms),
#      under the claim mutex;
#   C. as B, in the settle the claim runs before taking the mutex.
# In each: the mount SUCCEEDS and ZG 0 stays node 1's. After A, node 1
# stops beating and a later write claims ZG 0 and lands.
#
# DISCRIMINATION: with the claim returning the fence's -EBUSY, round A's
# mount fails; with it returning the replay's, B's and C's do.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in fence_stall_ms reclaim_stall_after_fence_ms zg_settle_locked; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
ZG_POKE="$(ct_helper zg_poke)"
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt zgcfr)"
ct_track mnt "$MNT"
zgowner() { "$ZG_POKE" "$1" 0 | sed -n 's/^owner_node_id=\([0-9]*\) .*/\1/p'; }

# <tag> <stall param> <settle_locked 0|1>; leaves the volume mounted when the mount succeeded
round() {
    local img dev rc mark mpid beater came
    img="$(ct_image 560 "zgcfr$1")"
    dev="$(ct_loop "$img")"
    IMG="$img"; DEV="$dev"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    ct_umount "$MNT"
    set_stale_window "$TEST_STALE_SECS"
    poke_dead_peer "$dev" 1 aa
    "$ZG_POKE" "$dev" 0 1 >/dev/null
    blockdev --flushbufs "$dev"
    ct_param_set zg_settle_locked "$3"
    # Short: the mount renews no lease of its own while the claim is held.
    ct_param_set "$2" 1500
    mark="$(dmesg_mark)"
    rc="$img.rc"; ct_track file "$rc"
    ( r=0; mount -t cetrafs "$dev" "$MNT" 2>/dev/null || r=$?; echo "$r" >"$rc" ) &
    mpid=$!
    for _ in $(seq 1 $((TEST_STALE_SECS * 20 + 150))); do
        [ "$(cat $P/$2)" = 0 ] && break
        [ -e "$rc" ] && break
        sleep 0.1
    done
    if [ "$(cat $P/$2)" != 0 ]; then
        ct_param_set "$2" 0
        wait "$mpid" || true
        RES="held=no rc=$(cat "$rc" 2>/dev/null)"
        return
    fi
    # Node 1 remounts: same row, no departure recorded (the no-CAW mount
    # gate stamped it DEAD), and it keeps beating, as a mounted node does.
    ( while [ ! -e "$rc" ]; do
        "$NPOKE" "$img" 1 --depart 0 >/dev/null 2>&1 || true
        "$NPOKE" "$img" 1 --beat >/dev/null 2>&1 || true
        sleep 0.2
    done ) &
    beater=$!
    wait "$mpid" || true
    kill "$beater" 2>/dev/null || true; wait "$beater" 2>/dev/null || true
    came="$(dmesg_since "$mark" | grep -c 'node 1 came back' || true)"
    RES="held=yes came_back=$came rc=$(cat "$rc") owner=$(zgowner "$img")"
    ct_param_set "$2" 0
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
check() { # <round> <what>
    log "$1: $RES"
    [ "$(get held "$RES")" = yes ] && [ "$(get came_back "$RES")" -ge 1 ] ||
        fail "$1: setup: the claim was not held, or node 1's return was not seen ($RES)"
    [ "$(get rc "$RES")" = 0 ] && [ "$(get owner "$RES")" = 1 ] &&
        pass "$1: $2: the mount succeeded and ZG 0 is still node 1's" || fail "$1: $2: $RES"
}

round a fence_stall_ms 1
check A "came back before the fence"
if [ "$(get rc "$RES")" = 0 ]; then
    # Node 1 goes quiet for good: a write needs a group and must get ZG 0.
    ct_param_set zg_settle_locked 0
    wait_out_stale_window
    OK=0
    for _ in $(seq 1 10); do
        dd if=/dev/urandom of="$MNT/f" bs=1M count=1 conv=fsync status=none 2>/dev/null && { OK=1; break; }
        sleep 2
    done
    OWNER="$(zgowner "$IMG")"
    ME="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    [ "$OK" = 1 ] && [ "$OWNER" = "$ME" ] && pass "A: once node 1 stopped beating, a write claimed ZG 0 and landed" ||
        fail "A: write ok=$OK, ZG 0 owner=$OWNER, this node=$ME"
    ct_umount "$MNT"
fi
round b reclaim_stall_after_fence_ms 1
check B "came back between the fence and the replay"
[ "$(get rc "$RES")" = 0 ] && ct_umount "$MNT"
round c reclaim_stall_after_fence_ms 0
check C "the same, in the settle before the claim mutex"
[ "$(get rc "$RES")" = 0 ] && ct_umount "$MNT"
ct_exit
