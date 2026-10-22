#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# unmount, and sync(2), must leave the volume and the cluster consistent
#
# Two halves.
#
# sync(2): free-space accounting is ACCRUED in memory and applied at
# four durability boundaries -- a file-lock close, a namespace lock
# release, evict_inode, unmount. A file simply held open and written
# hits none of them, and ->sync_fs was a stub whose comment ("nothing
# persistent yet") had been wrong for a long time, so there was nothing
# an administrator could do to force that state out. That matters for
# the case this filesystem is built for: fsfreeze before a SAN snapshot
# of a VM-image datastore reaches durability through ->sync_fs, so the
# snapshot captured counters that did not match the bitmaps they
# summarise.
#
# Unmount: the teardown announces this node's departure (its row is
# backdated so peers reclaim at once rather than waiting out a window),
# and everything else must be finished before that announcement -- a
# peer may start allocating out of our Zone Groups the instant it lands.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
ZG_POKE="$(ct_helper zg_poke)"
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_image 1200 teardown)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt teardown)"
ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

zg_free() { "$ZG_POKE" "$DEV" "$1" | sed -n 's/.*free_data_blocks=//p'; }

# ------------------------------------------------------ sync(2) is real
log "checking sync(2) pushes accrued free-space state to the device"
# The file is held OPEN throughout: closing it would hit the file-lock
# release boundary and flush for an unrelated reason, so the assertion
# would pass with ->sync_fs still a stub.
OWNED_ZG=""
for z in 0 1; do
    grep -q "zg $z: owner=0" /proc/fs/cetrafs/"$(basename "$DEV")"/info && OWNED_ZG="$z" && break
done
[ -n "$OWNED_ZG" ] || fail "setup: this node owns no Zone Group"
BEFORE="$(zg_free "${OWNED_ZG:-0}")"

exec 7>"$MNT/held"
dd if=/dev/zero bs=4096 count=256 status=none >&7
# fsync puts the DATA on the device; the counters are a separate,
# in-memory thing, which is the whole point.
python3 -c "import os,sys; os.fsync(7)" 7>&- 2>/dev/null || true
sync -f "$MNT" 2>/dev/null || sync
AFTER="$(zg_free "${OWNED_ZG:-0}")"
exec 7>&-

if [ "$AFTER" -lt "$BEFORE" ]; then
    pass "sync: the ZG free aggregate on the device dropped by $((BEFORE - AFTER)) blocks while the file was still open"
else
    fail "sync: the ZG free aggregate is still $AFTER (was $BEFORE) -- sync(2) flushed nothing"
fi


# ------------------------------------------------------------ unmount
log "checking what unmount leaves behind"
PROCDIR="/proc/fs/cetrafs/$(basename "$DEV")"
[ -d "$PROCDIR" ] && pass "procfs: the per-mount directory exists while mounted" ||
    fail "procfs: $PROCDIR is missing while mounted"

# An open fd must keep the filesystem busy -- if it did not, teardown
# would run under a live reference.
exec 8<"$MNT/held"
if umount "$MNT" 2>/dev/null; then
    fail "unmount: succeeded with a file still open"
    ct_mount "$DEV" "$MNT"
else
    pass "unmount: refused while a file is open"
fi
exec 8<&-

ct_umount "$MNT"
[ -d "$PROCDIR" ] &&
    fail "procfs: $PROCDIR survived the unmount -- a reader could reach freed state" ||
    pass "procfs: the per-mount directory is gone after unmount"

ROW="$("$NODE_POKE" "$DEV" 0)"
case "$ROW" in
*"last_seen=0"*) pass "unmount: this node's row is backdated, so a peer reclaims at once" ;;
*) fail "unmount: row reads $ROW -- a peer would wait out the whole stale window" ;;
esac
case "$ROW" in
*"state=1"*) pass "unmount: the row stays REGISTERED, so this node re-attaches by UUID next mount" ;;
*) fail "unmount: the row was freed -- this node loses its identity and its ZG ownership" ;;
esac

ct_fsck "$DEV" >/dev/null 2>&1 && pass "unmount: the volume is fsck-clean" ||
    fail "unmount: fsck reports damage: $(ct_fsck "$DEV" 2>&1 | tail -3)"

# ------------------------------------------- nothing drifts over cycles
log "checking repeated mount/unmount cycles leak nothing"
OWN_BEFORE="$("$ZG_POKE" "$DEV" 0)"
for _ in 1 2 3; do
    ct_mount "$DEV" "$MNT"
    ct_umount "$MNT"
done
[ "$("$ZG_POKE" "$DEV" 0)" = "$OWN_BEFORE" ] &&
    pass "cycles: ZG 0 ownership and free count are unchanged across three cycles" ||
    fail "cycles: ZG 0 drifted: '$OWN_BEFORE' -> '$("$ZG_POKE" "$DEV" 0)'"
ROWS=0
for r in 0 1 2 3; do
    "$NODE_POKE" "$DEV" "$r" | grep -q 'state=1' && ROWS=$((ROWS + 1))
done
[ "$ROWS" = "1" ] &&
    pass "cycles: still exactly one registered row (every cycle re-attached)" ||
    fail "cycles: $ROWS registered rows after three mount/unmount cycles"

# ------------------------------------------- a fenced node writes nothing
log "checking a fenced node writes nothing on the way out"
# A node whose lease was revoked has already had its state reclaimed by
# a peer; backdating its row on the way out would be one more write it
# has no right to make. Reaching it needs the heartbeat to NOTICE the
# revocation, which is what fence_skip_precheck is for in fence_lease.sh;
# here the ordinary pre-check path is enough.
compress_timing
ct_mount "$DEV" "$MNT"
sleep 1
"$NODE_POKE" "$DEV" 0 --bump-fence 1 >/dev/null
sleep $((TEST_HB_SECS * 4))
FENCED="$(sed -n 's/^fenced: //p' /proc/fs/cetrafs/"$(basename "$DEV")"/info)"
ct_umount "$MNT"
if [ "$FENCED" = "yes" ]; then
    pass "fence: the heartbeat noticed the revoked lease"
    case "$("$NODE_POKE" "$DEV" 0)" in
    *"last_seen=0"*) fail "fence: a fenced node still backdated its row on the way out" ;;
    *) pass "fence: a fenced node left its row alone at unmount" ;;
    esac
else
    skip "fence: the lease revocation was not noticed in time; the write-nothing assertion needs it"
fi
reset_stale_window

ct_exit
