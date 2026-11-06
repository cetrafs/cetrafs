#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free that finds a dead owner's queue full leaves the takeover to the heartbeat
#
# A free into a Zone Group another node owns is queued for that owner.
# When the queue is full and the owner is dead, the Zone Group has to be
# taken over -- but the free used to do it ITSELF: fence, replay the dead
# node's journal, recount every member bitmap, all inside truncate or
# punch (inode_lock and invalidate_lock held), evict (possibly the inode
# shrinker) or a directory free (the namespace lock). A guest discard
# stalled its VM, and every reader of the image, for the whole replay
# (audit 2026-11-06 M6). The free now takes the logged-leak path and
# flags the Zone Group; the heartbeat adopts it on its next tick.
#
# Staged: Zone Group 1 holds a file's blocks and belongs to a dead
# peer's row; pf_force_foreign routes the free through the queue (a loop
# device has no CAW) and pf_force_queue_full reports it full. zg_steal_stall_ms
# holds the takeover for 4 s once it has its stale verdict, so whichever
# thread runs the takeover pays for it. The rm must not; the Zone Group
# must still end up adopted.
#
# DISCRIMINATION: with the takeover run inline, the rm takes the 4 s.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in pf_force_foreign pf_force_queue_full zg_steal_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"

DEV="$(ct_dev 1200 pfadopt)"
MNT="$(ct_mnt pfadopt)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0
info() { cat "$(ct_procdir "$DEV")/info"; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OWNED="$(info | sed -n 's/.*zg \([0-9]*\): owner=[0-9]* (this node).*/\1/p')"
[ "$(wc -w <<<"$OWNED")" = 1 ] || { fail "setup: this node owns Zone Groups '$OWNED', want one"; ct_umount "$MNT"; ct_exit; }
OTHER=$((1 - OWNED))
ct_umount "$MNT"
# Fill the owned group so the file's blocks land in the other one.
for b in $(ct_bgs_of_zg "$DEV" "$OWNED"); do
    "$BG_POKE" "$DEV" "$b" 0 sync-zg >/dev/null
    "$BG_POKE" "$DEV" "$b" 0 fill-bitmap >/dev/null
done
ct_mount "$DEV" "$MNT"
ct_param_set auto_defrag 0
dd if=/dev/zero of="$MNT/f" bs=64k count=16 conv=fsync status=none
ct_umount "$MNT"
"$ZG_POKE" "$DEV" "$OTHER" 1 >/dev/null # Zone Group OTHER now belongs to node 1...
poke_dead_peer "$DEV" 1 aa              # ...whose row stops beating

set_stale_window "$TEST_STALE_SECS"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
info | grep -qE "zg $OTHER: owner=1( |,|$)" || { fail "setup: Zone Group $OTHER is not node 1's: $(info | grep "zg $OTHER:")"; ct_umount "$MNT"; ct_exit; }
wait_out_stale_window # the dead row is judged stale from here on
MARK="$(dmesg_mark)"
ct_param_set zg_steal_stall_ms 4000
ct_param_set pf_force_foreign 1 # a loop device has no CAW, so frees would skip the queue
ct_param_set pf_force_queue_full 1
T0="$(date +%s%N)"
rm "$MNT/f"
sync -f "$MNT" 2>/dev/null || true
MS=$((($(date +%s%N) - T0) / 1000000))
ct_param_set pf_force_queue_full 0
ct_param_set pf_force_foreign 0
ADOPTED=""
for _ in $(seq 1 30); do
    info | grep -q "zg $OTHER: owner=[0-9]* (this node)" && { ADOPTED=1; break; }
    sleep 1
done
ct_param_set zg_steal_stall_ms 0
# Only the full-queue path takes this Zone Group over here (the node owns
# another one, and the scrub is off), so an adoption is the proof the
# free reached it -- whichever thread ran it.
[ -n "$ADOPTED" ] || { fail "setup: nobody adopted Zone Group $OTHER: $(info | grep "zg $OTHER:")"; ct_umount "$MNT"; ct_exit; }
[ "$MS" -lt 2000 ] && pass "the free into a dead owner's full queue returned in ${MS} ms" ||
    fail "the free into a dead owner's full queue took ${MS} ms -- it ran the takeover itself"
dmesg_since "$MARK" | grep -q "queue full, DROPPING" && pass "the free took the logged leak path" ||
    fail "the free did not take the leak path"
dmesg_since "$MARK" | grep -q "ZG $OTHER: adopted from its stale owner" &&
    pass "the heartbeat adopted Zone Group $OTHER from its dead owner" ||
    fail "Zone Group $OTHER was adopted, but not by the heartbeat"
ct_umount "$MNT"
ct_exit
