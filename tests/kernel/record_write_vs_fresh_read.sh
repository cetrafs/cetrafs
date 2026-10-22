#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an inode-record write is never reverted by a concurrent forced-fresh read
#
# ioutil.c's begin/end protocol exists because a forced-fresh reader
# clears uptodate and re-reads straight into a buffer's memory: done to a
# buffer a local thread is partway through modifying, the modification is
# overwritten and then persisted over. That was measured once as 12 of
# 292 directory entries silently lost.
#
# cetrafs_bh_end_update() closes it by marking the buffer dirty BEFORE
# unlocking, so a reader that takes the lock afterwards sees dirty and
# leaves it alone. Three writers hand-rolled the sequence instead and got
# the order backwards -- unlock, THEN mark dirty -- leaving a window in
# which the buffer is uptodate, clean, and holding an image that exists
# only in memory. Among them was cetrafs_write_raw_inode(), the choke
# point every inode write in the filesystem goes through, and
# cetrafs_write_node_entry(), which writes the heartbeat and every
# registry claim.
#
# Here chmod() is the record write and open() of another file is the
# forced-fresh read. Each file is written once and left alone, so a
# reverted write IS that file's final state and a mode check finds it.
#
# DISCRIMINATION: the natural window is a few instructions, so this does
# not reliably fail on the unfixed code by itself -- the standard way to
# test a narrow race is to widen it. Measured by restoring the inverted
# order in cetrafs_write_raw_inode() with a 200us sleep in the window:
# 5 of this suite's 7 assertions failed -- a writer died outright, only
# 744 of 1200 files existed, 7 chmods were reverted (and stayed reverted
# across the remount), and fsck reported leaked blocks plus an allocated
# inode no directory entry names. Losing a record write does not just
# lose that field; it takes the namespace with it. With the helpers in
# place: 7 of 7 pass.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
STORM="$(ct_helper record_write_storm)"

DEV="$(ct_dev 560 rws)"
MNT="$(ct_mnt rws)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

WRITERS=6
PER=200
READERS=3
WANT=$((WRITERS * PER))
TARGET_MODE=751

log "checking $WANT record writes against $READERS concurrent forced-fresh readers"
mkdir "$MNT/storm"
if "$STORM" "$MNT/storm" "$WRITERS" "$PER" "$READERS"; then
    pass "record storm: all $WANT files created and chmod'd"
else
    fail "record storm: a writer failed outright"
fi
sync

FOUND="$(find "$MNT/storm" -type f | wc -l)"
[ "$FOUND" = "$WANT" ] && pass "record storm: all $WANT files are present" ||
    fail "record storm: $FOUND files present, expected $WANT"

WRONG="$(find "$MNT/storm" -type f ! -perm "$TARGET_MODE" | wc -l)"
if [ "$WRONG" = "0" ]; then
    pass "record storm: every file kept its chmod (no record write reverted)"
else
    fail "record storm: $WRONG of $WANT files lost their chmod -- a forced-fresh read reverted the record write"
    find "$MNT/storm" -type f ! -perm "$TARGET_MODE" -printf '%M %p\n' | head -3
fi

# The same check after a remount: a write that survived in the page cache
# but never reached the device would pass above and fail here.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
WRONG2="$(find "$MNT/storm" -type f ! -perm "$TARGET_MODE" | wc -l)"
[ "$WRONG2" = "0" ] && pass "record storm: every chmod is still there after a remount" ||
    fail "record storm: $WRONG2 files lost their chmod across the remount"
ct_umount "$MNT"

log "checking fsck agrees"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "cetrafs fsck: OK" &&
    pass "fsck: clean after the record storm" ||
    fail "fsck: problems after the record storm: $(echo "$FSCK_OUT" | grep -iE 'ERR|WARN' | head -2 | tr '\n' ' ')"

ct_exit
