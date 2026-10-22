#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# clock skew between nodes cannot make a live peer look dead
#
# The bug this guards against cost 85 of 200 directory entries on real
# hardware: the two nodes' clocks were 1h55m apart, staleness was
# computed as "our_now - peer.last_seen > window", and the node that was
# AHEAD declared its live peer dead, broke its namespace lock and both
# nodes then mutated the same dirent blocks unsynchronised.
#
# Liveness is now observer-local: a peer is dead when its own hb_seq
# stops advancing for a window of OUR clock. No cross-node timestamp
# comparison exists anywhere. The control is the second half: the same
# row, once its hb_seq really does stop, must still be judged dead.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

log "checking that CLOCK SKEW cannot make a live peer look dead"
# The regression test for the bug that forced this mechanism to change.
#
# Two real nodes sharing a LUN had wall clocks 1h55m apart, neither
# running a working NTP service. Staleness was `my_now - peer.last_seen
# > window` -- OUR clock minus a stamp written by THEIRS -- so the node
# whose clock ran ahead saw its live peer as permanently dead. It broke
# that peer's namespace lock on a shared directory; both nodes then
# wrote the same dirent blocks with no mutual exclusion, and one
# 200-file run lost 85 entries and leaked 85 inodes and 13885 blocks.
#
# The verdict itself is what this asserts, straight out of procfs: a row
# whose timestamp looks ~2.8h stale to us but whose heartbeat is visibly
# advancing must read stale=no. Deliberately NO zone group is poked to
# this row -- a live foreign ZG claim on a no-CAW device correctly
# refuses the mount outright, which would get in the way of observing
# the verdict.
SKEW_IMG="$(mktemp /tmp/cetrafs-skew-XXXXXX.img)"
truncate -s 560M "$SKEW_IMG"
SKEW_LOOPDEV="$(losetup --find --show "$SKEW_IMG")"
SKEW_MNT="$(mktemp -d /tmp/cetrafs-skew-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$SKEW_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$SKEW_LOOPDEV" "$SKEW_MNT"
umount "$SKEW_MNT"

set_stale_window "$TEST_STALE_SECS"
# last_seen ~2.8h in the past by OUR clock: exactly what a healthy peer
# whose clock runs behind ours writes on every single heartbeat.
mount -t cetrafs "$SKEW_LOOPDEV" "$SKEW_MNT"
# Poked AFTER the mount: the no-CAW gate watches every registered row
# for a full window before admitting a second mounter, and nothing beats
# this one during a mount, so poking first would have the gate correctly
# judge it dead -- which is the gate's job and not what this is about.
"$NODE_POKE" "$SKEW_LOOPDEV" 1 1 dd "$(($(date +%s) - 9999))" >/dev/null
SKEW_PROC="/proc/fs/cetrafs/$(basename "$SKEW_LOOPDEV")/cluster"

# Beat for comfortably longer than the window, checking the verdict after
# each beat. Under the old rule this read stale=yes from the very first
# check and never recovered, because the timestamp alone decided it.
SKEW_SAW_STALE=no
for _ in $(seq 1 $((TEST_STALE_SECS * 2 + 4))); do
    "$NODE_POKE" "$SKEW_LOOPDEV" 1 --beat-keep-time >/dev/null 2>&1 || true
    sleep 1
    grep -q '^node 1:.*stale=yes' "$SKEW_PROC" 2>/dev/null && SKEW_SAW_STALE=yes
done
[ "$SKEW_SAW_STALE" = no ] &&
    pass "skew: a live peer whose timestamp looks 2.8h stale is never declared dead" ||
    fail "skew: a LIVE, heartbeating peer was declared dead because its clock disagrees with ours"

# The control. Same row, same ancient timestamp, nothing beating it now:
# it must go stale, or the assertion above would hold simply because
# nothing is ever declared stale any more.
sleep $((TEST_STALE_SECS + 3))
grep -q '^node 1:.*stale=yes' "$SKEW_PROC" 2>/dev/null &&
    pass "skew: the same row IS declared dead once its heartbeat stops" ||
    fail "skew: a peer that stopped heartbeating was never declared dead -- the check above proves nothing"

umount "$SKEW_MNT"
reset_stale_window
rmdir "$SKEW_MNT"
losetup -d "$SKEW_LOOPDEV"
rm -f "$SKEW_IMG"


ct_exit
