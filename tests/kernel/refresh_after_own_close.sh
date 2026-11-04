#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's change must be applied at open even while this node's inode
# is still flagged dirty from its own, already-published close
#
# cetrafs_apply_raw_to_vfs_inode() refuses to stamp the device's record
# over UNWRITTEN local changes, and judged "unwritten" by the VFS dirty
# flag. But close publishes the record through a CAS of its own, which
# leaves that flag set until writeback's ->write_inode runs, ~30 s
# later. So: this node writes and closes; a peer opens, extends and
# closes within those 30 s; this node reopens -- and the refresh saw
# "dirty", declined, and said nothing. The open went on with this node's
# old i_size and its cached extent tree: an append lands at the stale
# end of file, over the peer's data, and reads stop at the old size.
#
# Now the decline needs real local state: an unpublished extent shadow,
# or stat fields that differ from what this node last published.
#
# Staged with one node: the peer's close is a record rewritten on the
# device (a larger size, file_seq stamped by another node id), inside
# the window, while the kernel's inode is still dirty.
#
# DISCRIMINATION: with the old test (decline on I_DIRTY_ALL alone), the
# reopen reports the old size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 ownclose)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ownclose)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((${NODE:-0} + 1) % 4))

for round in 1 2 3; do
    F="$MNT/f$round"
    # Write and close, no sync: the inode stays dirty for the writeback
    # interval, though close has published the record.
    python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT,0o644); os.write(fd,b"a"*8192); os.close(fd)' "$F"
    INO="$(stat -c %i "$F")"
    SZ0="$("$POKE" "$IMG" size "$INO")"
    [ "$SZ0" = 8192 ] || { fail "round $round: setup: close did not publish size 8192 (device says $SZ0)"; continue; }
    # The peer: extended to 16 KiB, and the last stamp is its own.
    "$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
    "$POKE" "$IMG" peerseq "$INO" "$PEER" 2>/dev/null
    OUT="$(python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDWR); print(os.fstat(fd).st_size); os.close(fd)' "$F")"
    [ "$OUT" = 16384 ] &&
        pass "round $round: reopened within the writeback window, this node sees the peer's size ($OUT)" ||
        fail "round $round: reopened within the writeback window, this node still has size $OUT -- the peer's record was not applied"
done

ct_umount "$MNT"
ct_exit
