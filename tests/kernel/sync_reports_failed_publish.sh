#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# syncfs does not report success over a record whose writeback publish failed
#
# The VFS clears an inode's dirt before calling write_inode; a publish
# that failed there was not re-dirtied, and sync_fs walks only inodes
# with pending blocks -- so syncfs(2) returned 0 with the record still
# unpublished (audit 2026-11-06 L16). A failed publish now re-dirties
# the inode and marks it; sync_fs retries it and reports a second
# failure.
#
# Staged on dirt only writeback publishes: f's blocks already exist, so
# an overwrite through an fd held open (its close would publish on its
# own) moves mtime and nothing else -- the data path's pending-block
# publish has nothing to do. The next writeback publish fails
# (write_inode_fail_once); after sync -f the record on the device must
# carry the new mtime.
#
# DISCRIMINATION: with the failure dropped, sync -f succeeds and the
# record keeps the old mtime.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/write_inode_fail_once ] || { skip "write_inode_fail_once is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 syncpub)"
MNT="$(ct_mnt syncpub)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
: >"$MNT/f"
dd if=/dev/urandom of="$MNT/f" bs=4096 count=16 conv=fsync status=none
sync
INO="$(stat -c %i "$MNT/f")"
recmtime() { "$LOCK_POKE" "$DEV" "$INO" --rec | sed -n 's/.* mtime=\([0-9]*\).*/\1/p'; }
M0="$(recmtime)"
[ -n "$M0" ] || { fail "setup: no mtime in the record dump"; ct_umount "$MNT"; ct_exit; }
sleep 2 # the overwrite's mtime must differ by whole seconds
FIFO="$(ct_tmp syncpub-fifo)"; rm -f "$FIFO"; mkfifo "$FIFO"
python3 - "$MNT/f" "$FIFO" <<'PY' &
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, os.urandom(4096), 0)   # an existing block: no allocation
open(sys.argv[2]).read()             # held open across the sync
os.close(fd)
PY
PID=$!
sleep 1
WANT="$(stat -c %Y "$MNT/f")"
[ "$WANT" -gt "$M0" ] || { fail "setup: the overwrite did not move mtime ($M0 -> $WANT)"; echo go >"$FIFO"; wait "$PID" || true; ct_umount "$MNT"; ct_exit; }
ct_param_set write_inode_fail_once 1
RC=0; sync -f "$MNT" || RC=$?
LEFT="$(cat /sys/module/cetrafs/parameters/write_inode_fail_once)"
ct_param_set write_inode_fail_once 0
M1="$(recmtime)"
echo go >"$FIFO"
wait "$PID" || true
[ "$LEFT" = N ] || { fail "setup: the sync never reached a writeback publish"; ct_umount "$MNT"; ct_exit; }
if [ "$RC" = 0 ]; then
    [ "$M1" = "$WANT" ] && pass "syncfs returned success only once the record carried the new mtime" ||
        fail "syncfs returned success with the record unpublished (mtime $M1 on the device, $WANT in core)"
else
    pass "syncfs reported the failed publish (rc $RC) instead of claiming success"
fi
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -E '^ERR' <<<"$OUT" | head -2)"
ct_exit
