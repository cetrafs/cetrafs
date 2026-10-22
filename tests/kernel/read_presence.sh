#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the read-open presence bitmask stops a peer unlinking what we are reading
#
# A read-only open takes no cross-node lock -- lock-free readers are the
# whole design -- which left nothing stopping a peer unlinking a file this
# node is reading, freeing its blocks and handing them to a new file while
# the open fd read on. Each node sets its own bit in the inode record on
# its FIRST read-open and clears it on its LAST, and unlink consults it.
#
# A STALE peer's bit must NOT block the unlink (and is cleared on sight),
# or one crashed reader would make a file permanently un-unlinkable.
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

log "checking cross-node read presence"
# A read-only open takes no lock -- lock-free readers are the whole
# design -- which left nothing stopping a peer unlinking a file this
# node is reading: the peer's evict frees the blocks, the allocator
# hands them to a new file, and the reader, still going through an
# already-open fd that never re-looks-up, silently gets that other
# file's data. The fix is a presence BITMASK in the inode record that a
# reader publishes on its first read-open and withdraws on its last.
echo "read-presence payload" >"$LOCK_MNT/rp"
RP_INO="$(stat -c '%i' "$LOCK_MNT/rp")"

RP_IDLE="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$RP_INO")"
case "$RP_IDLE" in
    *"readers=0x0") pass "read-presence: an unopened file has an empty reader set" ;;
    *) fail "read-presence: expected readers=0x0 on an idle file, got '$RP_IDLE'" ;;
esac

# Hold two read-only fds: the bit appears on the FIRST and must survive
# the first close, going away only on the last -- the same last-one-out
# rule the write lock uses, so repeated local opens cost nothing on the
# wire.
exec 7<"$LOCK_MNT/rp"
RP_ONE="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$RP_INO")"
case "$RP_ONE" in
    *"readers=0x1") pass "read-presence: a read-open publishes this node (bit 0)" ;;
    *) fail "read-presence: after a read-open, got '$RP_ONE', expected readers=0x1" ;;
esac

exec 6<"$LOCK_MNT/rp"
exec 7<&-
RP_TWO="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$RP_INO")"
case "$RP_TWO" in
    *"readers=0x1") pass "read-presence: closing one of two readers keeps the bit set" ;;
    *) fail "read-presence: after closing one of two readers, got '$RP_TWO', expected readers=0x1" ;;
esac

exec 6<&-
RP_NONE="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$RP_INO")"
case "$RP_NONE" in
    *"readers=0x0") pass "read-presence: the LAST reader withdraws this node" ;;
    *) fail "read-presence: after the last close, got '$RP_NONE', expected readers=0x0" ;;
esac

# Unlinking a file THIS node has open must still work -- that case was
# always correct (frees defer to evict_inode) and must not regress into
# a refusal.
exec 7<"$LOCK_MNT/rp"
rm -f "$LOCK_MNT/rp" 2>/dev/null &&
    pass "read-presence: unlinking a file THIS node has open still succeeds" ||
    fail "read-presence: unlink of a locally-open file was wrongly refused"
exec 7<&-

# Now a LIVE peer holding it open for read: the unlink must be refused
# rather than pulling the blocks out from under it.
echo "peer-read payload" >"$LOCK_MNT/rp2"
RP2_INO="$(stat -c '%i' "$LOCK_MNT/rp2")"
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$RP2_INO" --reader 1 >/dev/null
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# Poked AFTER the mount, deliberately. Liveness is observed hb_seq
# PROGRESS, so a row with a fresh timestamp and a frozen counter reads
# "alive" only while nothing has been watching it -- and the no-CAW
# mount gate now watches, spending exactly that budget before it will
# admit a second mounter.
"$NODE_POKE" "$LOCK_LOOPDEV" 1 1 cc "$(date +%s)" >/dev/null
if rm -f "$LOCK_MNT/rp2" 2>/dev/null; then
    fail "read-presence: unlink succeeded while a LIVE peer had the file open for read"
else
    pass "read-presence: unlink refused while a live peer is reading"
fi
[ -e "$LOCK_MNT/rp2" ] && pass "read-presence: the refused unlink left the file intact" ||
    fail "read-presence: the file vanished despite the unlink being refused"

# A reader on a node that has since gone STALE must not block forever --
# its fd died with it, so the bit is ignored and cleared.
umount "$LOCK_MNT"
set_stale_window "$TEST_STALE_SECS"
# Retire the previous section's peer first, so the mount below has no
# registered row to watch. Otherwise the no-CAW gate spends a whole
# window inside the mount -- measured from the same instant the peer
# watch is seeded, so the "first sight" assertion below would be made
# one window late.
"$NODE_POKE" "$LOCK_LOOPDEV" 1 0 cc 0 >/dev/null 2>&1 || true
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# The peer appears only now, so this really is first sight. Poking it
# before the mount would no longer be: the no-CAW gate watches every
# registered row for a full window before admitting us, so by the time
# such a mount returned the row would already have been judged -- which
# is the gate doing its job, and not what this assertion is about.
poke_dead_peer "$LOCK_LOOPDEV" 1 cc
# Having seen row 1's hb_seq exactly once, this node cannot yet tell a
# dead peer from a quiet one, so it must NOT reclaim: refusing here is
# the conservative half of the rule.
rm -f "$LOCK_MNT/rp2" 2>/dev/null &&
    fail "read-presence: unlinked past a peer's reader bit on first sight, before it could possibly be judged dead" ||
    pass "read-presence: a not-yet-judgeable peer's reader bit still blocks the unlink"
wait_out_stale_window
rm -f "$LOCK_MNT/rp2" 2>/dev/null &&
    pass "read-presence: a STALE peer's reader bit does not block the unlink" ||
    fail "read-presence: a stale peer's reader bit blocked the unlink forever"
reset_stale_window
"$NODE_POKE" "$LOCK_LOOPDEV" 1 0 cc 0 >/dev/null 2>&1 || true


ct_exit
