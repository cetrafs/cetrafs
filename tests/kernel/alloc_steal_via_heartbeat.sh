#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation whose only space is a dead peer's Zone Group leaves the takeover to the heartbeat
#
# When every Zone Group this node owns is full, the allocator claims one
# more -- and the candidate may belong to a dead peer. The allocator
# then took it over ITSELF: fence, replay the dead node's whole journal
# with its claim wait, recount every member bitmap, all from inside
# write(2), fallocate or a page fault, holding inode_lock,
# invalidate_lock or mmap_lock, and uninterruptibly. Audit M6 moved the
# identical takeover off the free path and left this caller of the same
# claim behind. The allocator now flags the Zone Group, kicks the
# heartbeat's maintenance pass and waits for it, killably.
#
# Staged: Zone Group A is this node's and full, Zone Group B belongs to
# a dead peer's row, zg_steal_stall_ms holds the takeover after its
# verdict.
#  (1) A write that needs the space: the heartbeat must be the one that
#      adopts B, and the write must land and read back.
#  (2) Staged again; the writer gets SIGKILL inside the takeover: it
#      must be gone at once, not after the stall.
#
# DISCRIMINATION: with the takeover run in the writer, the heartbeat
# never logs the adoption and the SIGKILL waits out the stall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_steal_stall_ms ] || { skip "zg_steal_stall_ms is missing"; ct_exit; }
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"

DEV="$(ct_dev 1200 allocsteal)"
MNT="$(ct_mnt allocsteal)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0
info() { cat "$(ct_procdir "$DEV")/info"; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OWNED="$(info | sed -n 's/.*zg \([0-9]*\): owner=[0-9]* (this node).*/\1/p')"
[ "$(wc -w <<<"$OWNED")" = 1 ] || { fail "setup: this node owns Zone Groups '$OWNED', want one"; ct_umount "$MNT"; ct_exit; }
OTHER=$((1 - OWNED))
ct_umount "$MNT"
for b in $(ct_bgs_of_zg "$DEV" "$OWNED"); do
    "$BG_POKE" "$DEV" "$b" 0 sync-zg >/dev/null
    "$BG_POKE" "$DEV" "$b" 0 fill-bitmap >/dev/null
done
# Zone Group OTHER belongs to node 1, whose row stops beating; this
# node's group stays full (nothing here frees in it).
stage() {
    "$ZG_POKE" "$DEV" "$OTHER" 1 >/dev/null
    poke_dead_peer "$DEV" 1 aa
    blockdev --flushbufs "$DEV"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set auto_defrag 0
    info | grep -qE "zg $OTHER: owner=1( |,|$)" || { fail "setup: Zone Group $OTHER is not node 1's: $(info | grep "zg $OTHER:")"; ct_umount "$MNT"; ct_exit; }
    wait_out_stale_window # the dead row is judged stale from here on
    info | grep -qE "zg $OTHER: owner=1( |,|$)" || { fail "setup: something took Zone Group $OTHER before the write"; ct_umount "$MNT"; ct_exit; }
}
verdict() {
    for _ in $(seq 1 80); do
        dmesg_since "$1" | grep -q "reclaiming ZG $OTHER from stale node 1" && return 0
        sleep 0.25
    done
    return 1
}
set_stale_window "$TEST_STALE_SECS"

# --- 1: a write that waits for the heartbeat's takeover
stage
MARK="$(dmesg_mark)"
ct_param_set zg_steal_stall_ms 3000
RC=0
dd if=/dev/urandom of="$MNT/w1" bs=64k count=16 conv=fsync status=none || RC=$?
ct_param_set zg_steal_stall_ms 0
verdict "$MARK" || { fail "setup: the write never led to a takeover of Zone Group $OTHER"; ct_umount "$MNT"; ct_exit; }
[ "$RC" = 0 ] && pass "the write that needed a dead peer's Zone Group succeeded" ||
    fail "the write that needed a dead peer's Zone Group failed ($RC)"
dmesg_since "$MARK" | grep -q "ZG $OTHER: adopted from its stale owner" &&
    pass "the heartbeat took Zone Group $OTHER over, not the writer" ||
    fail "Zone Group $OTHER was not taken over by the heartbeat -- the writer ran the takeover itself"
SUM="$(md5sum <"$MNT/w1")"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(md5sum <"$MNT/w1")" = "$SUM" ] && pass "it reads back after a remount" || fail "the write reads back wrong after a remount"
ct_umount "$MNT"

# --- 2: the writer is killable while the takeover runs
stage
MARK="$(dmesg_mark)"
ct_param_set zg_steal_stall_ms 8000
dd if=/dev/urandom of="$MNT/w2" bs=64k count=16 conv=fsync status=none 2>/dev/null &
DPID=$!
verdict "$MARK" ||
    { fail "setup: round 2's write never led to a takeover"; ct_param_set zg_steal_stall_ms 0; wait "$DPID" || true; ct_umount "$MNT"; ct_exit; }
sleep 0.5 # inside the stall now
log "writer's stack in the stall: $(grep -oE 'cetrafs_[a-z_]+' "/proc/$DPID/stack" 2>/dev/null | head -3 | tr '\n' ' ')"
T0="$(date +%s%N)"
kill -9 "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true
MS=$((($(date +%s%N) - T0) / 1000000))
[ "$MS" -lt 2000 ] && pass "the writer died on SIGKILL in ${MS} ms -- it was not running the takeover" ||
    fail "the writer took ${MS} ms to die on SIGKILL -- it ran the dead peer's takeover itself"
for _ in $(seq 1 40); do
    dmesg_since "$MARK" | grep -q "ZG $OTHER: adopted from its stale owner" && break
    sleep 0.5
done
ct_param_set zg_steal_stall_ms 0
dmesg_since "$MARK" | grep -q "ZG $OTHER: adopted from its stale owner" &&
    pass "the heartbeat finished the takeover the killed writer asked for" ||
    fail "the takeover the killed writer asked for never finished"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -i err <<<"$OUT" | head -2)"
ct_exit
