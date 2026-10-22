#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file lock held by a dead node is reclaimed at open time
#
# lock.c's lazy counterpart to the periodic ZG reclaim: nothing scans for
# stale file locks, because nothing needs to know about one except
# whoever next tries to open that file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
INODE_LOCK_POKE="$(ct_helper inode_lock_poke)"

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

# Row 1 has to be a REGISTERED peer whose heartbeat then stops. Without
# this the row would be FREE, which also reads as "stale" -- so the
# reclaim would still happen and the assertions would still pass, for
# entirely the wrong reason. The thing under test is reclaiming from a
# node that really did register and then die.
umount "$LOCK_MNT"
poke_dead_peer "$LOCK_LOOPDEV" 1 aa
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"

log "checking stale file-lock reclaim"
# This section needs node 1 to become judgeably dead, so compress the
# window.
set_stale_window "$TEST_STALE_SECS"
# lock.c's lazy reclaim-at-open-time path, as opposed to zonegroup.c's
# periodic/mount-time pass: poke victim's lock to "exclusively held by
# node 1" and let node 1's row go stale.
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO" 1 1 >/dev/null

DMESG_MARK_LOCK="$(dmesg_mark)"
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# A remount discards this node's record of having watched node 1's
# heartbeat, so the peer has to be observed to be still again before it
# can be judged dead. That is the honest cost of deciding liveness
# locally instead of from a timestamp a peer wrote.
wait_out_stale_window

if echo more >>"$LOCK_MNT/victim" 2>/dev/null; then
    pass "lock reclaim: write-open of a stale-locked file succeeded (reclaimed from node 1)"
else
    fail "lock reclaim: write-open of a stale-locked file unexpectedly still rejected"
fi

LOCK_RECLAIM_LOG="$(dmesg_since "$DMESG_MARK_LOCK")"
if echo "$LOCK_RECLAIM_LOG" | grep -q "reclaiming a stale lock from node 1"; then
    pass "lock reclaim: dmesg confirms the stale lock was reclaimed, not just silently bypassed"
else
    fail "lock reclaim: expected a 'reclaiming a stale lock from node 1' dmesg line"
fi

# The write-open just above already reclaimed victim's lock for this
# node, so re-poke it back to "exclusively held by node 1" (still the
# same now-stale row) to test unlink's own stale-bypass directly --
# without an open() first, since dir.c's check must reach the same
# "not actually in use" conclusion on its own.
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO" 1 1 >/dev/null
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
wait_out_stale_window

if rm -f "$LOCK_MNT/victim" 2>/dev/null; then
    pass "lock reclaim: unlink of a stale-locked file succeeded without needing an open() first"
else
    fail "lock reclaim: unlink of a stale-locked file unexpectedly rejected"
fi
reset_stale_window

umount "$LOCK_MNT"
rmdir "$LOCK_MNT"
losetup -d "$LOCK_LOOPDEV"
rm -f "$LOCK_IMG"


ct_exit
