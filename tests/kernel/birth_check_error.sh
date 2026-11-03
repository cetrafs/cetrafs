#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create that fails after its birth claim gives the claim back, so the number is reclaimed
#
# A create reusing a dead inode number takes its bit, claims the dead
# record (ns lock = this node), then re-reads the bit fresh. When that
# read failed, the create returned the error and KEPT the claim: bit set,
# record dead and locked by this node. Every scrub skipped it (a locked
# record is somebody's operation in flight), so the number was never
# reclaimed -- and its record still carried the previous life's extents,
# naming blocks that life's evict had freed. Once the allocator handed
# those to other files, fsck reported them "referenced by more than one
# inode" and "referenced by an inode but marked FREE". A churn run under
# load produced it about once in twenty: the re-read was a plain
# sb_bread() of a block every concurrent creator invalidates, and racing
# one of those invalidations comes back NULL -- a spurious -EIO.
#
# The fix reads that bit with cetrafs_bread_retry() and, on a real
# failure, releases the claim (BIRTH_ABORT) before returning. The race
# itself is the length of one block read and does not reproduce on
# demand, so this suite fails the check deterministically
# (birth_check_fail) and asserts the unwind.
#
# DISCRIMINATION: with the claim kept (the old unwind), the record stays
# locked by this node and the scrub never frees the number -- both
# assertions below fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/birth_check_fail ] || { skip "birth_check_fail is missing"; ct_exit; }

SBPOKE="$(ct_helper sb_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_dev 560 birthchk)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt birthchk)"
ct_mkfs_small "$DEV" >/dev/null
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
# A fast scrub: the mount reads the interval when it queues the first cycle.
ct_param_set hb_interval_secs 2
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_param_set scrub 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

bit() { # <ino>: the inode's bit, read off the backing file
    python3 -I - "$BACK" "$IBM" "$1" <<'PY'
import os, sys
back, ibm, ino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
b = ino - 1
fd = os.open(back, os.O_RDONLY)
print((os.pread(fd, 1, ibm * 4096 + b // 8)[0] >> (b % 8)) & 1)
os.close(fd)
PY
}

# A dead number: written once (so its record is checksummed, which is
# what makes the create claim it), then unlinked; its bit is clear and it
# is the lowest free number, so the next create takes it.
dd if=/dev/urandom of="$MNT/old" bs=4096 count=8 status=none
sync
N="$(stat -c %i "$MNT/old")"
rm "$MNT/old"
sync
[ "$(bit "$N")" = 0 ] || { fail "setup: ino $N's bit is still set after the unlink"; ct_exit; }

ct_param_set birth_check_fail 1
if touch "$MNT/new" 2>/dev/null; then
    GOT="$(stat -c %i "$MNT/new")"
    fail "setup: the create succeeded (ino $GOT) -- the injected failure was not reached"
    ct_param_set birth_check_fail 0
    ct_exit
fi
LEFT="$(cat /sys/module/cetrafs/parameters/birth_check_fail)"
ct_param_set birth_check_fail 0
[ "$LEFT" = 0 ] && [ "$(bit "$N")" = 1 ] &&
    pass "setup: the create claimed ino $N and failed at the bit check" ||
    { fail "setup: knob left=$LEFT, bit=$(bit "$N") -- the create did not fail where intended"; ct_exit; }

LOCK="$("$LPOKE" "$BACK" "$N")"
grep -q ' ns_owner=65535 ' <<<"$LOCK" &&
    pass "the failed create gave its claim back (ino $N's record is unlocked)" ||
    fail "the failed create kept its claim: $LOCK"

# The number is now an ordinary orphan: bit set, record dead and
# unlocked. The scrub must reclaim it.
freed=0
for _ in $(seq 1 30); do
    [ "$(bit "$N")" = 0 ] && { freed=1; break; }
    sleep 1
done
[ "$freed" = 1 ] && pass "the scrub reclaimed ino $N" ||
    fail "ino $N is still allocated after 30 s of scrub cycles ($(sed -n 's/^scrub_cycles: //p' "$PROC/info" 2>/dev/null) cycles)"

echo again >"$MNT/again" && pass "creates work afterwards" || fail "a create after the failure failed"
ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! grep -qE '^(ERR|WARN)' <<<"$out"; then
    pass "fsck clean: no orphan left behind"
else
    fail "fsck rc=$rc: $(grep -E '^(ERR|WARN)' <<<"$out" | head -4)"
fi
ct_exit
