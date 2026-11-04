#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a zone group steal judged before its owner came back does not land after
#
# A peer steals a stale node's Zone Group in three steps: the verdict
# (its row stopped beating), the fence and journal replay, and a swap
# that checked only that the record still names that owner. The owner
# remounting in between re-attaches to the SAME row -- the id matches
# again -- finds the ZG still its own on the device, and allocates from
# it; then the steal lands and the thief allocates from it too: two
# nodes, one bitmap, blocks handed out twice.
#
# Now the swap also requires the record's hb_seq to be the one the
# verdict read, and a mount re-asserts each ZG it still owns with a swap
# that moves hb_seq on.
#
# Staged with this node as the THIEF: ZG 0 belongs to a dead node 1;
# the heartbeat's steal is held after its verdict (zg_steal_stall_ms)
# while node 1's re-assert is played on the device. The steal must give
# up, and ZG 0 must still be node 1's.
#
# Round B: this node as the OWNER -- its remount must move hb_seq on.
#
# DISCRIMINATION: with the steal comparing the owner id alone, ZG 0
# ends up this node's; without the re-assert at mount, round B's hb_seq
# does not move.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_steal_stall_ms ] || { skip "zg_steal_stall_ms is missing"; ct_exit; }
ZG_POKE="$(ct_helper zg_poke)"

IMG="$(ct_image 560 zgsteal)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgsteal)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"

set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa
"$ZG_POKE" "$DEV" 0 1 >/dev/null
ct_param_set zg_steal_stall_ms 6000

MARK="$(dmesg_mark)"
# In the background: the steal can be the mount's own (it claims a ZG
# before it returns), and the stall holds the mount with it.
mount -t cetrafs "$DEV" "$MNT" &
MPID=$!
# The verdict: logged before the fence, replay and stall.
for _ in $(seq 1 $((TEST_STALE_SECS * 4 + 30))); do
    dmesg_since "$MARK" | grep -q 'reclaiming ZG 0 from stale node 1' && break
    sleep 0.5
done
dmesg_since "$MARK" | grep -q 'reclaiming ZG 0 from stale node 1' ||
    { fail "setup: this node never judged node 1 stale"; ct_param_set zg_steal_stall_ms 0; wait "$MPID" || true; ct_umount "$MNT"; ct_exit; }
# Node 1 comes back and re-asserts, while the steal is held.
"$ZG_POKE" "$IMG" 0 bumpseq >/dev/null
ct_param_set zg_steal_stall_ms 0
wait "$MPID" || { fail "the mount failed"; ct_exit; }
pass "setup: the steal was judged and held; node 1's re-assert played meanwhile"

OWNER=""
for _ in $(seq 1 30); do
    OWNER="$("$ZG_POKE" "$IMG" 0 | sed -n 's/^owner_node_id=\([0-9]*\) .*/\1/p')"
    { [ "$OWNER" != 1 ] || dmesg_since "$MARK" | grep -q 'lost race for ZG 0'; } && break
    sleep 0.5
done
log "after the held steal: ZG 0 owner=$OWNER; $(dmesg_since "$MARK" | grep -o 'ZG claim: lost race for ZG 0' | head -1)"
[ "$OWNER" = 1 ] && pass "the steal gave up: ZG 0 is still node 1's" ||
    fail "the steal landed on top of node 1's re-assert: ZG 0 is now node $OWNER's -- two owners"

ct_umount "$MNT"

# --- B: the other half. The owner's remount must move hb_seq on, or a
# steal judged while it was away still matches.
ct_param_set zg_steal_stall_ms 0
IMG2="$(ct_image 560 zgsteal2)"
DEV2="$(ct_loop "$IMG2")"
ct_mkfs_small "$DEV2" >/dev/null
ct_mount "$DEV2" "$MNT"
OWN="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV2")/info")"
ct_umount "$MNT"
[ "$("$ZG_POKE" "$DEV2" 0 | sed -n 's/^owner_node_id=\([0-9]*\) .*/\1/p')" = "$OWN" ] ||
    fail "B: setup: ZG 0 is not this node's after the first mount"
S1="$("$ZG_POKE" "$DEV2" 0 seq)"
ct_mount "$DEV2" "$MNT"
ct_umount "$MNT"
S2="$("$ZG_POKE" "$DEV2" 0 seq)"
[ "$S2" -gt "$S1" ] && pass "B: the owner's remount re-asserted ZG 0 (hb_seq $S1 -> $S2)" ||
    fail "B: the owner's remount left ZG 0's hb_seq at $S2 -- a steal judged while it was away would still land"

ct_exit
