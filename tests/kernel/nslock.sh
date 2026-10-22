#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the per-inode namespace lock is taken, scoped, released, and stealable when stale
#
# Every namespace mutation brackets itself in nslock.c's per-inode lock.
# The dangerous failure is a LEAKED lock: it would wedge every other node
# out of that directory forever and nothing else would notice, so the
# first assertion walks every inode after a full round of operations and
# requires the lock field back at its unlocked sentinel.
#
# Then: a lock held by a LIVE foreign node refuses the operation, a lock
# on one directory does not block work in another (the whole point of
# replacing the device-wide mutex), and a lock held by a STALE node is
# broken and the operation proceeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
INODE_LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

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

log "checking the per-inode namespace lock"
# Still mounted on $LOCK_LOOPDEV/$LOCK_MNT. Every namespace mutation now
# brackets itself in nslock.c's per-inode lock instead of the old
# device-wide cluster mutex, so the thing that must hold is: the lock is
# always RELEASED by the time the operation returns. A leaked lock is
# the dangerous failure here -- it would silently wedge every other node
# out of that directory forever, and nothing else in this suite would
# notice, since the leaking node itself is still allowed in.
NSROOT_INO="$(stat -c '%i' "$LOCK_MNT")"
mkdir -p "$LOCK_MNT/nsdir"
NSDIR_INO="$(stat -c '%i' "$LOCK_MNT/nsdir")"
echo hello >"$LOCK_MNT/nsdir/f1"
NSF1_INO="$(stat -c '%i' "$LOCK_MNT/nsdir/f1")"
ln "$LOCK_MNT/nsdir/f1" "$LOCK_MNT/nsdir/f2"
mv "$LOCK_MNT/nsdir/f2" "$LOCK_MNT/nsdir/f3"
chmod 600 "$LOCK_MNT/nsdir/f1"
python3 -c "import os,sys; os.setxattr(sys.argv[1], 'user.ns', b'v')" "$LOCK_MNT/nsdir/f1"
rm -f "$LOCK_MNT/nsdir/f3"
sync

NS_LEAKED=""
for NSI in "$NSROOT_INO" "$NSDIR_INO" "$NSF1_INO"; do
    NSDUMP="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$NSI")"
    case "$NSDUMP" in
        *"ns_owner=65535 readers=0x0") ;;
        *) NS_LEAKED="$NS_LEAKED ino=$NSI($NSDUMP)" ;;
    esac
done
[ -z "$NS_LEAKED" ] &&
    pass "nslock: mkdir/create/link/rename/chmod/setxattr/unlink all released the namespace lock" ||
    fail "nslock: namespace lock left held after the operation returned:$NS_LEAKED"

# The lock must also be genuinely TAKEN, not just always-free: a stale
# foreign holder has to be broken, and a *live* one has to block. Poke a
# live foreign holder onto nsdir while unmounted, then confirm a create
# inside it is refused rather than racing the (simulated) peer.
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$NSDIR_INO" --ns 1 >/dev/null
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# Poked AFTER the mount, deliberately. Liveness is observed hb_seq
# PROGRESS, so a row with a fresh timestamp and a frozen counter is only
# "alive" for as long as nothing has been watching it -- and the no-CAW
# mount gate now watches, blocking a full window before it will admit a
# second mounter. Poking before the mount would spend exactly the
# observation budget this section depends on.
"$NODE_POKE" "$LOCK_LOOPDEV" 1 1 bb "$(date +%s)" >/dev/null
if timeout 20 touch "$LOCK_MNT/nsdir/blocked" 2>/dev/null; then
    fail "nslock: create inside a directory held by a LIVE foreign node unexpectedly succeeded"
else
    pass "nslock: create inside a directory held by a live foreign node is refused"
fi
[ -e "$LOCK_MNT/nsdir/blocked" ] &&
    fail "nslock: the refused create still left a dirent behind" ||
    pass "nslock: the refused create left the directory untouched"

# The whole point of Phase C: that block is scoped to ONE directory. The
# device-wide mutex it replaced would have stalled this too.
if timeout 20 touch "$LOCK_MNT/elsewhere" 2>/dev/null; then
    pass "nslock: a lock on one directory does not block work in another"
else
    fail "nslock: a lock held on nsdir wrongly blocked a create in the root directory"
fi
rm -f "$LOCK_MNT/elsewhere"

# Now make that same holder stale: the lock must be broken and the
# create must go through, exactly as a stale ZG or file lock is reclaimed.
umount "$LOCK_MNT"
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$LOCK_LOOPDEV" 1 bb
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
wait_out_stale_window
if touch "$LOCK_MNT/nsdir/unblocked" 2>/dev/null; then
    pass "nslock: a namespace lock held by a STALE node is broken and the op proceeds"
else
    fail "nslock: create inside a directory held by a stale node was still refused"
fi
NSDUMP="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$NSDIR_INO")"
case "$NSDUMP" in
    *"ns_owner=65535 readers=0x0") pass "nslock: the stolen lock was released again afterwards" ;;
    *) fail "nslock: after breaking a stale lock, dump is '$NSDUMP', expected ns_owner=65535 readers=0x0" ;;
esac
rm -f "$LOCK_MNT/nsdir/unblocked"
"$NODE_POKE" "$LOCK_LOOPDEV" 1 0 bb 0 >/dev/null 2>&1 || true
reset_stale_window


ct_exit
