#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stale peer's zone group is reclaimed on a heartbeat tick
#
# A ZG owned by a node whose heartbeat has demonstrably stopped must come
# back into use without this node needing to remount. Note what the
# assertion requires: NOT a reclaim at mount -- on first sight of a row
# this node has one observation of its hb_seq and cannot tell a dead peer
# from a quiet one, so it correctly declines, and the reclaim lands on a
# later tick once the counter has been seen to stop moving.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"

# A volume with one file, 'victim', whose inode number the pokes below
# address. Every suite that touches the on-disk lock fields starts from
# exactly this state, freshly built -- nothing here inherits anything
# from another suite.
LOCK_IMG="$(ct_image 560 lock)"
LOCK_LOOPDEV="$(ct_loop "$LOCK_IMG")"
LOCK_MNT="$(ct_mnt lock-mnt)"
ct_mkfs_small "$LOCK_LOOPDEV" >/dev/null
ct_track mnt "$LOCK_MNT"
ct_mount "$LOCK_LOOPDEV" "$LOCK_MNT"
require_cetrafs_mount "$LOCK_MNT"
echo "victim content" >"$LOCK_MNT/victim"
VICTIM_INO="$(stat -c '%i' "$LOCK_MNT/victim")"

log "checking stale ZG reclaim"
# Simulate "ZG0 is owned by node 1, but node 1's heartbeat died a long
# time ago": poke a fake REGISTERED row at index 1 with last_seen far in
# the past, then poke ZG0's owner to that row -- same zg_poke.c this
# project already uses for phase 10's foreign-claim gate test, just
# pointed at a now-demonstrably-stale row instead of a nonexistent one.
# Poking while unmounted, same reasoning as every other poke in this
# script: avoids racing the kernel's own buffer cache.
umount "$LOCK_MNT"
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$LOCK_LOOPDEV" 1 aa
"$ZG_POKE" "$LOCK_LOOPDEV" 0 1 >/dev/null

DMESG_MARK_ZG="$(dmesg_mark)"
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# NOT at mount any more. On first sight of row 1 this node has one
# observation of its hb_seq and cannot tell a dead peer from a quiet
# one, so it correctly declines to steal the ZG; the reclaim lands on a
# heartbeat tick once the counter has demonstrably stopped moving.
wait_out_stale_window
sleep $((TEST_HB_SECS * 2))

ZG_RECLAIM_LOG="$(dmesg_since "$DMESG_MARK_ZG")"
if echo "$ZG_RECLAIM_LOG" | grep -q 'reclaiming ZG 0 from stale node 1'; then
    pass "ZG reclaim: stale ZG0 (owned by node 1) was reclaimed once its heartbeat stopped"
else
    fail "ZG reclaim: expected a 'reclaiming ZG 0 from stale node 1' dmesg line, got: $(echo "$ZG_RECLAIM_LOG" | grep 'ZG claim:')"
fi
if echo "$ZG_RECLAIM_LOG" | grep -q 'ZG claim: own 1 of 1 zone group(s)'; then
    pass "ZG reclaim: this node owns the ZG again after reclaiming it"
else
    fail "ZG reclaim: expected 'own 1 of 1 zone group(s)', got: $(echo "$ZG_RECLAIM_LOG" | grep 'ZG claim:')"
fi


ct_exit
