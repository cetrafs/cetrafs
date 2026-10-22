#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the cross-node exclusive open-file lock, and local open refcounting
#
# Whole-file VMFS-style exclusivity, not POSIX byte ranges: a file one
# node holds for write is unopenable by any other node, for reading too.
# The local half is the subtle one -- the on-disk claim must survive the
# first of several local write-opens closing and clear only on the LAST,
# which is why lock.c keeps its own lock_writer_count rather than
# releasing on any close.
#
# Also checks the paths that never go through .open at all and so were
# invisible to the lock for a long time: unlink, chmod, truncate and
# setxattr against a file a live peer holds.
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

log "checking the cross-node exclusive open-file lock"

# This node's own local open/close refcounting: the lock must stay held
# until the *last* local write-opener closes it, not the first -- the
# whole reason lock.c tracks a per-inode lock_writer_count instead of
# just "any close releases it" (see lock.c's header comment). Two
# separate local write opens (fd 9, fd 8) on the same inode via `exec`
# keep real open file descriptors live across the dump checks below.
exec 9>>"$LOCK_MNT/victim"
DUMP1="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO")"
[ "$DUMP1" = "owner=0 mode=1 ns_owner=65535 readers=0x0" ] && pass "lock: first local write-open claims the lock (owner=0 mode=EXCLUSIVE)" ||
    fail "lock: after first write-open, dump is '$DUMP1', expected 'owner=0 mode=1 ns_owner=65535 readers=0x0'"

exec 8>>"$LOCK_MNT/victim"
DUMP2="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO")"
[ "$DUMP2" = "owner=0 mode=1 ns_owner=65535 readers=0x0" ] && pass "lock: a second local write-open (same node) is allowed, lock still held" ||
    fail "lock: after second write-open, dump is '$DUMP2', expected 'owner=0 mode=1 ns_owner=65535 readers=0x0'"

exec 9>&-
DUMP3="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO")"
[ "$DUMP3" = "owner=0 mode=1 ns_owner=65535 readers=0x0" ] && pass "lock: closing the first (of two) local write-opener keeps the lock held" ||
    fail "lock: after closing the first writer, dump is '$DUMP3', expected 'owner=0 mode=1 ns_owner=65535 readers=0x0' (lock released too early)"

exec 8>&-
DUMP4="$("$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO")"
[ "$DUMP4" = "owner=65535 mode=0 ns_owner=65535 readers=0x0" ] && pass "lock: closing the *last* local write-opener releases the lock" ||
    fail "lock: after closing the last writer, dump is '$DUMP4', expected 'owner=65535 mode=0 ns_owner=65535 readers=0x0'"

# Cross-node rejection: simulate "node 1, still alive, already holds
# this file open for write" by poking a fake REGISTERED row with a
# fresh heartbeat plus the lock fields, then confirm both a write-open
# and a read-open from this (different) node are rejected with -ETXTBSY.
# The foreign node must actually look alive here -- stale foreign claims
# are reclaimable (tested separately below), so an arbitrary out-of-thin-air
# id no longer exercises this rejection path.
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO" 1 1 >/dev/null
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
# Poked AFTER the mount, deliberately. Liveness is observed hb_seq
# PROGRESS, so a row with a fresh timestamp and a frozen counter is only
# "alive" for as long as nothing has been watching it -- and the no-CAW
# mount gate now watches, blocking a full window before it will admit a
# second mounter. Poking before the mount would spend exactly the
# observation budget this section depends on.
"$NODE_POKE" "$LOCK_LOOPDEV" 1 1 bb "$(date +%s)" >/dev/null

if echo more >>"$LOCK_MNT/victim" 2>/dev/null; then
    fail "lock: write-open of a foreign-locked file unexpectedly succeeded"
else
    pass "lock: write-open of a foreign-locked file correctly rejected"
fi

if cat "$LOCK_MNT/victim" >/dev/null 2>/dev/null; then
    fail "lock: read-open of a foreign-locked file unexpectedly succeeded"
else
    pass "lock: read-open of a foreign-locked file correctly rejected too (whole-file, not just write)"
fi

# Unlink must be blocked too, not just open() -- freeing victim's blocks
# while node 1 (still alive) might still be actively writing to them
# through its own open fd would be a real cross-node corruption path.
# cetrafs_unlink_locked()'s own lock check is what this
# exercises; the dirent must be left untouched on rejection.
if rm -f "$LOCK_MNT/victim" 2>/dev/null; then
    fail "lock: unlink of a foreign-locked file unexpectedly succeeded"
else
    pass "lock: unlink of a foreign-locked file correctly rejected"
fi
[ -e "$LOCK_MNT/victim" ] && pass "lock: victim still present after the rejected unlink" ||
    fail "lock: victim is gone despite the unlink being rejected"

# the whole setattr/xattr family must respect the lock too --
# path-based truncate(2)/chmod/setxattr never go through .open, so the
# open-time gate alone never covered them: one node could shrink (and
# free the blocks of!) or rewrite the record of a file another node was
# actively streaming to.
if chmod 600 "$LOCK_MNT/victim" 2>/dev/null; then
    fail "lock: chmod of a foreign-locked file unexpectedly succeeded"
else
    pass "lock: chmod of a foreign-locked file correctly rejected"
fi
if truncate -s 0 "$LOCK_MNT/victim" 2>/dev/null; then
    fail "lock: truncate of a foreign-locked file unexpectedly succeeded"
else
    pass "lock: truncate of a foreign-locked file correctly rejected"
fi
if python3 -c "import os,sys; os.setxattr(sys.argv[1], 'user.t', b'v')" "$LOCK_MNT/victim" 2>/dev/null; then
    fail "lock: setxattr on a foreign-locked file unexpectedly succeeded"
else
    pass "lock: setxattr on a foreign-locked file correctly rejected"
fi

# Clear the simulated foreign claim and confirm the file opens normally
# again -- the gate isn't permanently stuck once the lock clears.
umount "$LOCK_MNT"
"$INODE_LOCK_POKE" "$LOCK_LOOPDEV" "$VICTIM_INO" 65535 0 >/dev/null
# The simulated peer departs too -- otherwise every later mount in this
# suite spends a full watch window on the gate deciding whether a row
# that will never beat again is alive.
"$NODE_POKE" "$LOCK_LOOPDEV" 1 0 bb 0 >/dev/null
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"

GOT="$(cat "$LOCK_MNT/victim" 2>/dev/null)"
[ "$GOT" = "victim content" ] && pass "lock: file opens normally again once the foreign claim clears" ||
    fail "lock: reading after clearing the foreign claim gave '$GOT', expected 'victim content'"


ct_exit
