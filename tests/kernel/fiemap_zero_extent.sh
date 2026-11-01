#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# FIEMAP must not spin on an extent that claims zero length
#
# The fiemap walk steps by exactly the length it just reported:
#
#     cursor = best_start + best_len;
#
# so an extent of length zero leaves the cursor where it was, the same
# entry wins the next scan, and the loop never ends. It runs under
# inode_lock_shared, so it takes the file's other readers down with it,
# and any user can ask for it -- `filefrag` is a fiemap call.
#
# A zero-length extent is also not something fiemap can report: there is
# no way to express it. So it is skipped, loudly, and left for fsck,
# which is where a nonsense extent belongs.
#
# The same walk also gained a cond_resched(): the array is unsorted, so
# every step is a full scan, and on a tree with hundreds of thousands of
# extents that is a long time to hold a CPU without offering it up.
#
# Discrimination: NOT run against the unfixed kernel here, and the
# measurement is why. Reproduced once on a disposable node: a plain
# `filefrag` burned 146 seconds of CPU and was still climbing, in state
# R, and survived SIGKILL -- a tight kernel loop checks no signals, so
# there is nothing to deliver one to. The node needed `reboot -f`,
# because the unmount wanted the lock the loop was holding. In this
# gate the assertion is simply that the call RETURNS, which it cannot
# do if the loop is back.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fiemapzero)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fiemapzero)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

dd if=/dev/zero of="$MNT/f" bs=4096 count=8 conv=fsync status=none
INO="$(stat -c '%i' "$MNT/f")"
sync
ct_umount "$MNT"

# Entry 0 gets length zero, behind a restamped checksum: integrity
# perfect, content impossible.
"$POKE" "$IMG" extlen "$INO" 0 >/dev/null 2>&1 ||
    fail "could not poke a zero-length extent"
pass "an extent claiming zero length, behind a valid checksum"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"

# THE assertion: it comes back. 20s is far beyond what a 3-extent file
# needs; the fault is an endless loop, not a slow one.
RC=0
timeout 20 filefrag "$MNT/f" >/dev/null 2>&1 || RC=$?
[ "$RC" != 124 ] &&
    pass "fiemap returned instead of spinning on the zero-length extent (rc=$RC)" ||
    fail "fiemap did not return in 20s -- the cursor is not advancing, and it holds inode_lock_shared while it does not"

dmesg_since "$MARK" | grep -q "zero length" &&
    pass "and the nonsense extent was named rather than silently walked" ||
    log "note: no log line (the extent may not have been reached)"

# The lock has to be back: if the walk died holding it, everything below
# hangs instead of failing.
RC2=0
timeout 20 stat "$MNT/f" >/dev/null 2>&1 || RC2=$?
[ "$RC2" != 124 ] &&
    pass "the inode lock was released (stat still answers)" ||
    fail "stat hangs: inode_lock_shared is still held by the fiemap walk"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 &&
    log "note: fsck accepts it" ||
    pass "fsck reports the zero-length extent, which is where it belongs"

ct_exit
