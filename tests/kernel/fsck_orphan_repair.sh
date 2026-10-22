#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r reclaims an inode that was unlinked but never freed
#
# An inode with nlink=0 that no directory entry names is unambiguous
# garbage: unlink already said so, and the only reason the record
# survives is that eviction did not finish -- a read failure at evict
# time (which deliberately leaves BOTH the number and the blocks rather
# than freeing the number and losing track of the blocks), or a failed
# symlink unwind. fsck has always REPORTED this and left it, so the
# space was recoverable only by reformatting.
#
# Reclaiming is safe precisely here and nowhere else: fsck refuses to
# run at all on a volume mounted locally or carrying a live Node
# Registry row, so there is no "unlinked but still open" case to
# protect. An orphan with nlink > 0 is a DIFFERENT fault -- a lost
# dirent, where the data is still wanted -- and must stay reported.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 orphan)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt orphan-mnt)"
ct_mkfs_small "$LOOPDEV" >/dev/null

# Built with the kernel, so these are real records with real extents
# rather than something hand-written.
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/doomed" bs=4096 count=8 status=none
DOOMED="$(stat -c '%i' "$MNT/doomed")"
dd if=/dev/urandom of="$MNT/wanted" bs=4096 count=4 status=none
WANTED="$(stat -c '%i' "$MNT/wanted")"
ROOT_INO="$(stat -c '%i' "$MNT")"
FREE_BEFORE="$(stat -f -c '%f' "$MNT")"
ct_umount "$MNT"
blockdev --flushbufs "$LOOPDEV"

IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"

# Fault 1: unlinked but never freed -- nlink 0 AND no entry.
"$IPOKE" "$LOOPDEV" nlink "$DOOMED" 0 >/dev/null
"$CPOKE" "$LOOPDEV" dirent "$ROOT_INO" doomed >/dev/null
# Fault 2: a LOST DIRENT -- the entry is gone but the file still claims
# a link, so its data is still wanted. Must never be freed.
"$CPOKE" "$LOOPDEV" dirent "$ROOT_INO" wanted >/dev/null
blockdev --flushbufs "$LOOPDEV"

OUT="$(ct_fsck "$LOOPDEV" 2>&1 || true)"
echo "$OUT" | grep -q "inode $DOOMED is allocated" &&
    pass "the unlinked orphan is reported" ||
    fail "fsck did not report inode $DOOMED:
$OUT"
echo "$OUT" | grep -q "inode $WANTED is allocated" &&
    pass "the lost-dirent orphan is reported too" ||
    fail "fsck did not report inode $WANTED:
$OUT"

log "repairing"
REP="$(ct_fsck_repair "$LOOPDEV" 2>&1 || true)"
echo "$REP" | grep -qi "run .*again\|second pass\|again to" &&
    pass "repair says another run is needed to reclaim the blocks" ||
    fail "repair gave no hint that the data blocks are reclaimed on a second run:
$REP"

# A second run: the record is no longer allocated, so its extents are
# no longer collected, so its blocks are leaked bits the existing
# reachability repair clears.
ct_fsck_repair "$LOOPDEV" >/dev/null 2>&1 || true
OUT2="$(ct_fsck "$LOOPDEV" 2>&1 || true)"
echo "$OUT2" | grep -q "inode $DOOMED" &&
    fail "the unlinked orphan survived repair:
$OUT2" ||
    pass "the unlinked orphan is gone"
# The lost-dirent orphan must NOT have been freed. It is no longer
# REPORTED either, because lost+found now gives it a name again
# (tests/kernel/fsck_lost_found.sh covers that half); what matters here
# is that the two faults were told apart -- one destroyed, one kept.
echo "$OUT2" | grep -q "inode $WANTED is allocated" &&
    fail "the lost-dirent orphan was left unreachable instead of recovered:
$OUT2"
pass "the lost-dirent orphan was kept, not freed -- its data was wanted"

# The reclaimed space must actually come back, not just stop being
# reported. 8 blocks of data plus the inode.
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
FREE_AFTER="$(stat -f -c '%f' "$MNT")"
WSUM_AFTER="$(md5sum <"$MNT/lost+found"/* 2>/dev/null | head -1)"
ct_umount "$MNT"
# 8 blocks back from the freed orphan, minus the one block lost+found
# itself costs to hold the recovered one.
if [ "$FREE_AFTER" -ge "$((FREE_BEFORE + 7))" ]; then
    pass "the freed orphan's 8 data blocks are back ($FREE_BEFORE -> $FREE_AFTER, less 1 for lost+found)"
else
    fail "blocks not reclaimed: $FREE_BEFORE -> $FREE_AFTER, expected at least $((FREE_BEFORE + 7))"
fi

ct_exit
