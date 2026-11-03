#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the deferred retry of a failed namespace-lock release never clears a lock a live local operation holds
#
# A release that does not commit is queued, and the heartbeat retries it
# (nslock_release_retry.sh). Meanwhile the lock still reads OURS on the
# device, so the next local operation on that inode takes it straight
# back ("already ours") and becomes its live holder. Nothing took the
# queued retry away, and the retry's compare-and-swap cannot tell a
# leftover lock from a held one: both say "ours". So the next tick
# cleared the lock under the operation holding it, and a peer could
# then take it and mutate the same directory at the same time.
# nslock.c's comment said "the per-inode local mutex guarantees no live
# local holder" -- the retry never takes that mutex.
#
# The test makes a release fail, starts a second operation on the same
# directory that holds the lock (test-only nslock_hold_ms) while the
# heartbeat retry is allowed to commit, and watches the record: the
# lock must read ours for as long as that operation holds it.
#
# DISCRIMINATION (measured on the unfixed code): the record shows the
# lock FREE while the second operation still holds it, and that
# operation's release reports the lock found cleared. (The release used
# to say nothing -- a lock found cleared to NONE was reported through a
# field whose "nobody" value is NONE itself; fixed alongside.)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LPOKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 nsholder)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nsholder)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
: >"$MNT/d/f"
DINO="$(stat -c '%i' "$MNT/d/f")" # the file's own lock: see below
sync
ns_owner() { sed -n 's/.* ns_owner=\([0-9]*\) .*/\1/p' <<<"$("$LPOKE" "$BACK" "$DINO")"; }

MARK="$(dmesg_mark)"
# A release with nothing STAGED: setattr on a file locks the file's own
# record and writes it directly. A release that loses a staged update (a
# create's directory dirent_seq/size/nlink) stops the mount instead --
# tests/kernel/nslock_staged_publish_lost.sh.
ct_param_set nslock_release_fail 1
chmod 600 "$MNT/d/f" 2>/dev/null || true
ME="$(ns_owner)"
LOG="$(dmesg_since "$MARK")"
if grep -q "queued for retry" <<<"$LOG" && [ -n "$ME" ] && [ "$ME" != 65535 ]; then
    pass "a release did not commit: queued, and the record still says node $ME holds the lock"
else
    fail "setup: no queued release (owner '$ME') -- the retry this test races is not armed"
    ct_exit
fi

# A second operation on the same file, holding the lock for 4 s.
# The release failure stays armed while it acquires, so the retry cannot
# settle the entry first; then it is lifted and the next tick may commit.
ct_param_set nslock_hold_ms 4000
(chmod 640 "$MNT/d/f") &
OP=$!
sleep 0.5
ct_param_set nslock_release_fail 0

freed=0
samples=0
while kill -0 "$OP" 2>/dev/null; do
    o="$(ns_owner)"
    samples=$((samples + 1))
    if [ "$o" = 65535 ] && kill -0 "$OP" 2>/dev/null; then freed=1; fi
    sleep 0.2
done
wait "$OP" || true
ct_param_set nslock_hold_ms 0

[ "$samples" -ge 10 ] && pass "sampled the record $samples times while the operation held the lock" ||
    fail "setup: only $samples samples during the hold"
if [ "$freed" = 0 ]; then
    pass "the lock read ours for as long as the local operation held it"
else
    fail "the heartbeat retry CLEARED the lock while a local operation held it -- a peer could take it"
fi
LOG="$(dmesg_since "$MARK")"
if ! grep -qE "no longer ours at release|found CLEARED at release" <<<"$LOG"; then
    pass "the operation's own release found its lock still its own"
else
    fail "the operation's release found the lock gone: $(grep -E 'no longer ours|found CLEARED' <<<"$LOG" | tail -1)"
fi
o="$(ns_owner)"
[ "$o" = 65535 ] && pass "and released, the lock is free" || fail "after both releases the lock reads owner $o"

ct_umount "$MNT"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true # the deliberately-failed publish
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

ct_exit
