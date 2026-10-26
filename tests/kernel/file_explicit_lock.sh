#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Userspace-driven explicit whole-file lock via the standard flock(2).
#
# nofilelock turns off the open-time automatic lock so Proxmox live
# migration can open an image on both nodes. This hands that exclusion
# back to userspace, per-file, on demand -- through the STANDARD flock(2)
# interface (file_operations.flock), not a bespoke ioctl: flock(LOCK_EX)
# is a whole-file advisory exclusive lock with exactly this lock's
# fd-scoped lifetime. An orchestrator flock(LOCK_EX)s the file, releases
# only for the migration handoff window, and re-locks after.
#
# Exercised single-node here (real cross-node enforcement is ctest's
# explicit-lock scenario):
#   1. ENFORCEMENT is honored under nofilelock too -- a live foreign lock
#      refuses the open (file_lock_optional.sh asserts the OPPOSITE for a
#      mount with no explicit lock in play; the discriminator is whether a
#      lock is actually present).
#   2. flock(LOCK_EX)/flock(LOCK_UN) claim/clear the real on-disk lock and
#      the lock is released when the holding fd closes. Under the DEFAULT
#      mount the same calls report and suspend the automatic lock instead
#      (lock_suspend.sh covers that path properly).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { echo "SKIP: flock(1) not installed"; exit 0; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 xlock)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xlock)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo "victim content" >"$MNT/victim"
INO="$(stat -c '%i' "$MNT/victim")"
ct_umount "$MNT"

dump() { "$LOCK_POKE" "$DEV" "$INO"; }  # -> "owner=U mode=U ns_owner=U readers=0x.."

# ---------------------------------------------------------------- part 1
# A LIVE foreign EXCLUSIVE lock (owner node 1). Under nofilelock the open
# must be REFUSED -- enforcement honors a present lock in both modes.
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null   # owner node 1, EXCLUSIVE
log "nofilelock still ENFORCES a live foreign lock (the explicit-lock guarantee)"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null   # node 1 alive (after mount: before trips the gate)
if cat "$MNT/victim" >/dev/null 2>&1; then
    fail "nofilelock: open of a LIVE foreign-locked file succeeded -- enforcement is off"
else
    pass "nofilelock: a live foreign lock refuses the open (enforcement honored both modes)"
fi
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 bb 0 >/dev/null   # node 1 departs so the next mount gate does not wait

# ---------------------------------------------------------------- part 2
# A STALE foreign lock (owner node 1, never alive) is bypassed AND cleared
# to NONE so it does not linger.
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null   # re-arm: owner 1, EXCLUSIVE, no live row
log "nofilelock bypasses a STALE foreign lock and clears it"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
GOT="$(cat "$MNT/victim" 2>/dev/null || true)"
[ "$GOT" = "victim content" ] &&
    pass "nofilelock: a stale foreign lock does not block the open" ||
    fail "nofilelock: stale foreign lock still blocked the open: '$GOT'"
ct_umount "$MNT"
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "nofilelock: the stale foreign lock was cleared to NONE ($D)" ||
    fail "nofilelock: stale foreign lock NOT cleared -- it would linger ($D)"

# ---------------------------------------------------------------- part 3
# Under the DEFAULT mount flock no longer fails: LOCK_EX reports the
# automatic lock this node already holds and LOCK_UN SUSPENDS it, so the
# same fd sequence an orchestrator uses under nofilelock works unchanged
# on a default mount. Suspension itself is covered by lock_suspend.sh;
# this is the interop assertion that one script fits both modes.
log "default mount: flock reports and suspends the automatic lock"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
DNID="$(sed -n 's/^this_node_id: //p' "/proc/fs/cetrafs/$PROC_DEV/info")"
exec 8>>"$MNT/victim"
flock -x -n 8 && pass "default: flock(LOCK_EX) succeeds -- the lock is already ours" ||
    fail "default: flock(LOCK_EX) refused a lock this node already holds"
D="$(dump)"
echo "$D" | grep -q "owner=$DNID mode=1" &&
    pass "default: LOCK_EX left the automatic lock in place ($D)" ||
    fail "default: LOCK_EX disturbed the automatic lock ($D)"
flock -u 8 && pass "default: flock(LOCK_UN) succeeds (suspends the lock)" ||
    fail "default: flock(LOCK_UN) failed"
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "default: LOCK_UN surrendered the lock with the fd still open ($D)" ||
    fail "default: LOCK_UN did not surrender the lock ($D)"
exec 8>&-
ct_umount "$MNT"

# ---------------------------------------------------------------- part 4
# Under nofilelock flock(LOCK_EX) claims the real on-disk lock, flock(LOCK_UN)
# clears it, and closing the holding fd releases it. The lock lives on the
# shell's fd 9 (flock(1) locks it and returns, leaving it held), so it is
# observable on-disk between each step -- exactly flock's fd-scoped lifetime.
log "nofilelock: flock claims & clears the on-disk lock; closing the fd releases"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "/proc/fs/cetrafs/$PROC_DEV/info")"
exec 9>>"$MNT/victim"

flock -x -n 9 && pass "nofilelock: flock(LOCK_EX) succeeded" || fail "nofilelock: flock(LOCK_EX) failed"
D="$(dump)"
echo "$D" | grep -q "owner=$NID mode=1" &&
    pass "nofilelock: on-disk lock is EXCLUSIVE, owned by this node ($D)" ||
    fail "nofilelock: on-disk lock not claimed by node $NID ($D)"

flock -u 9 && pass "nofilelock: flock(LOCK_UN) succeeded" || fail "nofilelock: flock(LOCK_UN) failed"
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "nofilelock: LOCK_UN cleared the on-disk lock, fd still open ($D)" ||
    fail "nofilelock: LOCK_UN did not clear the lock ($D)"

flock -x -n 9 && pass "nofilelock: re-lock after unlock succeeded (the relock-after-migration case)" ||
    fail "nofilelock: relock failed"
D="$(dump)"
echo "$D" | grep -q "owner=$NID mode=1" &&
    pass "nofilelock: on-disk lock re-claimed ($D)" ||
    fail "nofilelock: relock did not re-claim ($D)"

# Close the fd WITHOUT an explicit unlock: the close must release it.
exec 9>&-
D="$(dump)"
echo "$D" | grep -q 'mode=0' &&
    pass "nofilelock: closing the holding fd released the lock (fd-scoped) ($D)" ||
    fail "nofilelock: lock still held after the fd closed ($D)"
ct_umount "$MNT"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
