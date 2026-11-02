#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nothing is taken from a stale peer whose lease could not be revoked
#
# Every reclaim -- replaying a stale peer's journal, taking its Zone
# Group, its file or namespace lock -- first bumps the peer's fence
# epoch, so that a peer which is slow rather than dead fences itself the
# moment it looks. That bump was best-effort: its error was logged and
# swallowed, and the reclaim went ahead. A peer that never learned it
# was declared dead then kept writing while its journal was replayed
# over the blocks it was working and its Zone Group was allocated from
# by somebody else.
#
# The stale peer is played on the device: a REGISTERED row that never
# beats, with one live entry in its journal over a zeroed directory
# block, and then owning every Zone Group. fence_peer_fail makes the
# revocation fail (the no-CAW mount gate's own fence is not affected).
#
# DISCRIMINATION (measured with the error swallowed again): the entry is
# replayed, and the mount takes node 1's Zone Group, while the fence is
# failing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_peer_fail ] || { skip "fence_peer_fail is missing"; ct_exit; }

JPOKE="$(ct_helper journal_poke)"
ZG_POKE="$(ct_helper zg_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 1100 ffr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ffr)"
PAYLOAD="$(ct_tmp ffr-payload)"
ct_mkfs "$DEV" -z 2 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/a"
sync
XINO="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"
BLK="$("$EXTENT" "$IMG" extent "$XINO" | cut -d' ' -f1)"
[ -n "$BLK" ] && [ "$BLK" -gt 0 ] || { fail "setup: no dirent block for directory ino $XINO"; ct_exit; }
blk_sum() { dd if="$DEV" bs=4096 skip="$BLK" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }

# The dead peer: its unfinished write of d's block is in its journal, and
# the block on the device never got it.
dd if="$DEV" of="$PAYLOAD" bs=4096 skip="$BLK" count=1 status=none
dd if=/dev/zero of="$DEV" bs=4096 seek="$BLK" count=1 conv=notrunc oflag=direct status=none
compress_timing
poke_dead_peer "$DEV" 1 aa
# This node keeps a Zone Group of its own, so the mount needs nothing of
# node 1's and the journal sweep is the path that reaches it.
"$ZG_POKE" "$DEV" 0 1 >/dev/null
"$ZG_POKE" "$DEV" 1 0 >/dev/null
"$JPOKE" "$DEV" 1 0 "$BLK" "$PAYLOAD" --guard-current >/dev/null
ZERO="$(blk_sum)"
WANT="$(sha256sum <"$PAYLOAD" | cut -d' ' -f1)"

ct_param_set fence_peer_fail 1
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
wait_out_stale_window
sleep $((TEST_HB_SECS * 3))
LOG="$(dmesg_since "$MARK")"
echo "$LOG" | grep -q "could not revoke stale node 1" && pass "setup: the fence on node 1 is failing" ||
    { fail "setup: no failed fence on node 1 -- nothing tried to reclaim from it"; ct_exit; }

[ "$(blk_sum)" = "$ZERO" ] && pass "the peer's journal was not replayed while its lease stood" ||
    fail "the peer's journal was replayed over its block without its lease revoked"
log "the fence lands: the reclaim goes ahead"
ct_param_set fence_peer_fail 0
MARK="$(dmesg_mark)"
wait_for 30 "[ \"\$(blk_sum)\" = '$WANT' ]" && pass "the peer's journal is replayed once its lease is revoked" ||
    fail "the peer's journal was never replayed"
dmesg_since "$MARK" | grep -q "revoked stale node 1's lease" && pass "after its lease was revoked" ||
    fail "no lease revocation logged before the replay"
[ -e "$MNT/d/a" ] && pass "and the directory reads its entry back" || fail "d/a is missing after the replay"
ct_umount "$MNT"

log "a mount that would have to take node 1's Zone Group"
"$ZG_POKE" "$DEV" 0 1 >/dev/null
"$ZG_POKE" "$DEV" 1 1 >/dev/null
poke_dead_peer "$DEV" 1 aa
owner() { "$ZG_POKE" "$DEV" "$1" | sed -n 's/^owner_node_id=\([0-9]*\).*/\1/p'; }
ct_param_set fence_peer_fail 1
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_track mnt "$MNT"
    fail "the mount took a Zone Group from node 1 without its lease revoked"
    ct_umount "$MNT"
else
    pass "the mount refuses rather than take a Zone Group without the lease"
fi
[ "$(owner 0)" = 1 ] && [ "$(owner 1)" = 1 ] && pass "both Zone Groups are still node 1's" ||
    fail "a Zone Group changed hands (owners $(owner 0) $(owner 1))"
ct_param_set fence_peer_fail 0
ct_mount "$DEV" "$MNT" && pass "with the fence landing, the mount takes one" ||
    fail "the mount fails even with the fence landing"
ct_umount "$MNT"
ct_exit
