#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace lock we could not give back must be retried, not abandoned
#
# The release is a compare-and-swap and it can fail. The code logged
# "leaving the lock for stale-reclaim", which describes what happened
# accurately and is a poor outcome: stale reclaim fires for a node that
# STOPPED heartbeating, and this one has not. The lock sat there until
# the node died or unmounted.
#
# The review calls that "peers block indefinitely". They do not --
# cetrafs_nslock_acquire() has a retry budget and returns -EBUSY -- so
# it is not a hang. It is worse in a quieter way: every namespace
# operation on that inode, from any node, fails for as long as the
# holder lives, and nothing anywhere is trying to fix it.
#
# A failed release is now remembered and retried on the heartbeat.
#
# Discrimination: drop the cetrafs_sb_nslock_defer() call and the lock
# is still held after several heartbeats -- the second assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 nsretry)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nsretry)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
set_stale_window "$TEST_STALE_SECS"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
DINO="$(stat -c '%i' "$MNT/d")"
sync

MARK="$(dmesg_mark)"
# A namespace operation whose release cannot commit.
ct_param_set nslock_release_fail 1
: > "$MNT/d/f" 2>/dev/null || true
sync
ct_param_set nslock_release_fail 0

dmesg_since "$MARK" | grep -q "queued for retry" &&
    pass "a release that did not commit was queued rather than abandoned" ||
    fail "no deferral logged: $(dmesg_since "$MARK" | grep -i nslock | tail -2)"

# THE assertion: a heartbeat tick clears it. Without the queue the lock
# stays held for the life of the mount.
for _ in $(seq 1 12); do
    dmesg_since "$MARK" | grep -q "release committed on retry\|no longer ours to release" && break
    sleep "$TEST_HB_SECS"
done

dmesg_since "$MARK" | grep -qE "release committed on retry|no longer ours to release" &&
    pass "the heartbeat gave the lock back" ||
    fail "the lock is still held after $((12 * TEST_HB_SECS))s: nothing retries, and stale-reclaim will not come while this node beats"

# A sanity check, NOT a test of the damage. The stuck lock is OURS, and
# this node's own acquire takes it back ("already ours"), so local
# operations never saw the problem -- it is peers that are refused.
# Showing that needs a second node, which is ctest's job; this only
# proves the retry did not break the ordinary path.
: > "$MNT/d/g" &&
    pass "local namespace operations still work (sanity -- the damage was to peers)" ||
    fail "the directory is refusing operations on this node too"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    { ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
      ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after repairing the deliberately-failed publish" ||
      fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"; }

ct_exit
