#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsync(2) on a DIRECTORY
#
# cetrafs_dir_fsync() replaced simple_fsync(), which is declared and
# exported only on very recent kernels and so would not build on the
# deployment kernel. The replacement is four lines, and this suite is
# what stops it being four unexamined lines.
#
# What a directory fsync has to do here is less than it looks: every
# namespace mutation already writes the directory's dirent blocks AND
# its inode record synchronously (cetrafs_journal_write_block() syncs
# the target under the namespace lock, and the record write passes
# sync=true), because a peer must never see a directory this node has
# published but not written. So the two things left are the device
# cache flush and -- the one with a real hazard behind it -- clearing
# the inode's VFS dirty state.
#
# That second one matters because a DIRTY inode is one
# cetrafs_apply_raw_to_vfs_inode() refuses to refresh, so a directory
# left dirty stops seeing peers' changes until write-back happens to run.
# Writing the record directly instead of going through sync_inode_metadata()
# would do exactly that, and several places originally made that mistake.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dirfsync)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dirfsync)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# fsync a directory the way applications actually do: open it read-only
# and fsync the fd. A filesystem with no .fsync for directories fails
# this outright, which is the first thing worth asserting.
dfsync() { python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    (os.fdatasync if len(sys.argv) > 2 else os.fsync)(fd)
finally:
    os.close(fd)" "$@"; }

# THE discriminating assertions in this suite. With no .fsync in
# cetrafs_dir_ops the VFS returns EINVAL and all three of these fail --
# measured. That is also the user-visible shape of the build break that
# prompted this suite: an application fsyncing a directory after a
# rename (every mail spool, every database, git) gets an error from a
# filesystem that should simply have said yes.
log "a directory can be fsynced at all"
mkdir "$MNT/d"
dfsync "$MNT/d" && pass "fsync() on a directory fd succeeds" || fail "fsync() on a directory failed"
dfsync "$MNT/d" datasync && pass "fdatasync() on a directory fd succeeds" ||
    fail "fdatasync() on a directory failed"
dfsync "$MNT" && pass "fsync() on the root directory succeeds" || fail "fsync() on root failed"

log "fsync must leave the directory refreshable, not dirty"
# MEASURED: this one does NOT currently discriminate, and saying so is
# worth more than implying it does.
#
# It passes against a build whose fsync writes the inode directly,
# which leaves the inode dirty and so stops it accepting cross-node
# refreshes. The reason is that a directory
# inode is never dirty here in the first place: mark_inode_dirty()
# appears only in file.c, because every namespace operation writes the
# directory's record synchronously rather than deferring it to
# write-back. So sync_inode_metadata() has nothing to clear.
#
# Kept as a statement of the invariant, in the same spirit as the
# CAW-hardware assertions: it is correct, it costs nothing, and the day
# something does mark a directory dirty it starts having teeth. The
# technique and the choice of the MODE as the observable come from
# tests/kernel/inode_dirty_after_metadata_op.sh, which measured that
# nlink is the wrong one.
mkdir "$MNT/busy"
for i in 1 2 3 4 5; do : >"$MNT/busy/f$i"; done
DINO="$(stat -c '%i' "$MNT/busy")"
dfsync "$MNT/busy"
sync
"$POKE" "$IMG" setmode "$DINO" 0040707 >/dev/null 2>&1
GOT="$(stat -c '%a' "$MNT/busy")"
[ "$GOT" = "707" ] &&
    pass "after fsync the directory still accepts a peer's change (it was left clean)" ||
    fail "after fsync the directory is dirty: the record says 707, this node still reports $GOT"

log "the directory's own record is durable after fsync"
# Not a crash test -- a loop device cannot lose power -- but the record
# on the DEVICE must already agree with the live directory, with no
# unmount and no write-back in between.
mkdir "$MNT/durable"
for i in $(seq 1 20); do : >"$MNT/durable/g$i"; done
PINO="$(stat -c '%i' "$MNT/durable")"
dfsync "$MNT/durable"
LIVE_SIZE="$(stat -c '%s' "$MNT/durable")"
# `extents`, not `dump`: dump prints the record as raw hex, extents
# prints the parsed fields including size.
DISK_SIZE="$("$POKE" "$IMG" extents "$PINO" | grep -oP 'size=\K[0-9]+')"
[ "$LIVE_SIZE" = "$DISK_SIZE" ] &&
    pass "the on-disk record matches the live directory after fsync (size $DISK_SIZE)" ||
    fail "live size $LIVE_SIZE but the record on disk says $DISK_SIZE"

log "...and the entries themselves survive a remount"
# The guarantee an application is actually buying: create, fsync the
# parent, and the names are there afterwards.
mkdir "$MNT/survive"
for i in $(seq 1 30); do : >"$MNT/survive/s$i"; done
dfsync "$MNT/survive"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
N="$(ls "$MNT/survive" | wc -l)"
[ "$N" = "30" ] && pass "all 30 entries are there after a remount" || fail "only $N entries survived"
[ "$(ls "$MNT/busy" | wc -l)" = "5" ] && pass "the earlier directory is intact too" ||
    fail "the busy directory lost entries"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
