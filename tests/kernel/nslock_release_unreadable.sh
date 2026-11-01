#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace-lock release that cannot even read the record is retried until the lock is gone
#
# A release that does not commit is queued and retried on the heartbeat
# (nslock_release_retry.sh). The queue entry carries the generation the
# retry must find -- and it was taken from the release's own fresh read.
# When EVERY read failed, that was never set: the entry carried
# generation 0, the retry's swap compared it with the record's real
# generation, called the mismatch "number reused" (-ESTALE), and dropped
# the entry. The lock then stayed on the record of a node that keeps
# beating, so stale-reclaim never comes for it, and every namespace
# operation on that directory from every other node fails -EBUSY.
#
# Judged on the device, not from the log: the lock owner the record
# holds after the retries have had time to run.
#
# DISCRIMINATION (measured on the unfixed code): the retry logs "no
# longer ours to release (-116)" and the directory's record still names
# this node as its namespace-lock holder.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NONE=65535

IMG="$(ct_image 560 nsunread)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nsunread)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
DINO="$(stat -c '%i' "$MNT/d")"
sync
ns_owner() { "$LOCK_POKE" "$DEV" "$DINO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p'; }
[ "$(ns_owner)" = "$NONE" ] && pass "setup: the directory's namespace lock starts free" ||
    { fail "setup: ns_owner=$(ns_owner) before anything ran"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set nslock_release_read_fail 1
: >"$MNT/d/f" 2>/dev/null || true
ct_param_set nslock_release_read_fail 0
if dmesg_since "$MARK" | grep -q "queued for retry"; then
    pass "setup: the release could not read the record and was queued"
else
    fail "setup: no deferral logged -- the path under test did not run: $(dmesg_since "$MARK" | grep -i nslock | tail -2)"
    ct_exit
fi
held="$(ns_owner)"
[ "$held" != "$NONE" ] && pass "setup: the lock is still on the record after the failed release (owner $held)" ||
    fail "setup: the lock was already clear -- nothing left for the retry to do"

if wait_for 30 '[ "$(ns_owner)" = '"$NONE"' ]' 2>/dev/null; then
    pass "the heartbeat retry cleared the lock on the device"
else
    fail "the lock is still held by $(ns_owner) -- the retry gave up on it: $(dmesg_since "$MARK" | grep -E 'retry|no longer ours' | tail -1)"
fi
: >"$MNT/d/g" && pass "the directory takes new names afterwards" || fail "the directory refuses new names"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    { ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
      ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after repairing the deliberately-failed publish" ||
      fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"; }
ct_exit
