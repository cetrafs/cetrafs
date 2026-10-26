#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Default-mount lock suspension: flock(LOCK_UN)/flock(LOCK_EX) hand this
# node's AUTOMATIC lock back and take it again, per file, without closing.
#
# Everything is locked by default; a file is unlocked only on request and
# only for as long as the request lasts -- strictly safer than nofilelock,
# which removes the lock from every file on every node permanently.
#
# The load-bearing invariant: while suspended the inode must look exactly
# like a nofilelock inode. On a default mount a WRITER publishes no bit in
# read_open_nodes (the lock marks it instead), so surrendering the lock
# without publishing leaves the record reading lock_mode=NONE,
# read_open_nodes=0 -- byte-identical to a file nobody has open -- to
# unlink, rename, link, truncate, setxattr, evict and the scrub's orphan
# reclaim. Each of those would then destroy a file a live writer is
# mid-I/O on. Part 2 below is that assertion; part 7 is its negative
# control.
#
# Single-node here. The destructive paths that invariant protects are
# genuinely cross-node and live in ctest's lock-suspend scenario.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { echo "SKIP: flock(1) not installed"; exit 0; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 lsusp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lsusp)"
PROC="$(ct_procdir "$DEV")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

echo "victim content" >"$MNT/victim"
INO="$(stat -c '%i' "$MNT/victim")"
NID="$(sed -n 's/^this_node_id: //p' "$PROC/info")"

# The record, read straight off the device -- never this kernel's view.
dump() { "$LOCK_POKE" "$DEV" "$INO"; }   # -> "owner=U mode=U ns_owner=U readers=0x.."
readers() { dump | sed -n 's/.*readers=\(0x[0-9a-f]*\).*/\1/p'; }
counter() { sed -n "s/^$1: //p" "$PROC/info"; }

# ---------------------------------------------------------------- part 1
# Baseline. A write-open claims the automatic lock and -- by design --
# publishes NO presence bit. That absence is exactly what makes the
# suspension below dangerous if done naively.
exec 9>>"$MNT/victim"
sync
D="$(dump)"
echo "$D" | grep -q "owner=$NID mode=1" &&
    pass "default: write-open claimed the automatic lock ($D)" ||
    fail "default: write-open did not claim the lock ($D)"
[ "$(readers)" = "0x0" ] &&
    pass "default: a writer publishes no presence bit (the hazard suspension must cover)" ||
    fail "default: unexpected presence bit for a plain writer ($(readers))"

# ---------------------------------------------------------------- part 2
# THE invariant: suspension clears the lock AND publishes presence, so the
# file still answers "someone is using me" to every destructive path.
S0="$(counter lock_suspends)"
flock -u 9 && pass "default: flock(LOCK_UN) suspended the automatic lock" ||
    fail "default: flock(LOCK_UN) failed"
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "suspend: the on-disk lock is released, fd still open ($D)" ||
    fail "suspend: the lock was not released ($D)"
[ "$(readers)" != "0x0" ] &&
    pass "suspend: this node is published in read_open_nodes -- a peer's unlink/scrub still sees a live user ($D)" ||
    fail "suspend: NO presence bit -- the file reads as unused; a peer would free its blocks ($D)"
[ "$(counter lock_suspends)" -eq "$((S0 + 1))" ] &&
    pass "suspend: counted in procfs info" ||
    fail "suspend: lock_suspends did not advance ($(counter lock_suspends), was $S0)"

# ---------------------------------------------------------------- part 3
# A second local write-open must NOT silently re-claim: the window belongs
# to whoever asked for it, and an unrelated opener closing it would strand
# a peer mid-handoff.
exec 7>>"$MNT/victim"
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "suspend: a second local write-open did not re-claim the lock ($D)" ||
    fail "suspend: an unrelated write-open silently closed the handoff window ($D)"
exec 7>&-

# ---------------------------------------------------------------- part 4
# The defragmenter pins this lock for a whole pass and its safety rests on
# the lock being ours. It must decline while it is not.
if [ -x "$ROOT/userspace/defrag.cetra" ]; then
    if "$ROOT/userspace/defrag.cetra" "$MNT/victim" >/dev/null 2>&1; then
        fail "suspend: defrag ran while the lock was surrendered -- it would relocate blocks a peer may be writing"
    else
        pass "suspend: defrag declines while the lock is surrendered"
    fi
fi

# ---------------------------------------------------------------- part 5
# Resume takes it back and withdraws the presence bit -- the mirror image,
# lock first, presence second.
R0="$(counter lock_resumes)"
flock -x -n 9 && pass "default: flock(LOCK_EX) resumed the lock" || fail "default: resume failed"
D="$(dump)"
echo "$D" | grep -q "owner=$NID mode=1" &&
    pass "resume: the lock is ours again ($D)" ||
    fail "resume: the lock was not re-claimed ($D)"
[ "$(readers)" = "0x0" ] &&
    pass "resume: the presence bit was withdrawn ($D)" ||
    fail "resume: presence bit left behind -- peers stay on the slow path forever ($D)"
[ "$(counter lock_resumes)" -eq "$((R0 + 1))" ] &&
    pass "resume: counted in procfs info" ||
    fail "resume: lock_resumes did not advance"

# A second LOCK_EX on an unsuspended file reports the automatic lock
# rather than failing -- so a caller need not know the mount mode.
flock -x -n 9 && pass "default: LOCK_EX on an already-held lock succeeds (not -EOPNOTSUPP)" ||
    fail "default: LOCK_EX refused a lock this node already holds"

# ---------------------------------------------------------------- part 6
# Closing the last writer WHILE suspended must withdraw the presence bit:
# it is the only thing still telling peers the file is in use here.
flock -u 9 >/dev/null
[ "$(readers)" != "0x0" ] || fail "suspend (2nd): no presence bit to withdraw"
exec 9>&-
sync
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "close-while-suspended: no lock left behind ($D)" ||
    fail "close-while-suspended: a lock was left on the record ($D)"
[ "$(readers)" = "0x0" ] &&
    pass "close-while-suspended: the presence bit was withdrawn ($D)" ||
    fail "close-while-suspended: presence bit leaked -- the file looks forever-open to every peer ($D)"

# ---------------------------------------------------------------- part 7
# NEGATIVE CONTROL for part 2. With the publish disabled, suspension
# leaves the record reading exactly like an unused file. If this does NOT
# reproduce, part 2 was asserting something that is true for another
# reason and proves nothing.
ct_param_set lock_suspend_skip_publish 1
exec 9>>"$MNT/victim"
flock -u 9 >/dev/null
D="$(dump)"
if echo "$D" | grep -q 'mode=0' && [ "$(readers)" = "0x0" ]; then
    pass "negative control: without the publish the file reads as unused -- part 2 discriminates ($D)"
else
    fail "negative control did not reproduce the hazard ($D) -- part 2's assertion proves nothing"
fi
flock -x -n 9 >/dev/null || true
exec 9>&-
ct_param_set lock_suspend_skip_publish 0

# ---------------------------------------------------------------- part 8
# Suspension must not disturb the ordinary path: a plain write with no
# suspension in play keeps the fast in-core predicate and never falls to
# the cross-node reconcile.
C0="$(counter file_cache_reconciles)"
dd if=/dev/zero of="$MNT/plain" bs=4096 count=256 2>/dev/null
sync
[ "$(counter file_cache_reconciles)" -eq "$C0" ] &&
    pass "unsuspended writes still take the fast path (no cache reconcile)" ||
    fail "an ordinary write now reconciles its cache -- the predicate fell to the slow branch"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
