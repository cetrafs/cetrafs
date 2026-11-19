#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r must not manufacture corruption when /lost+found cannot be built
#
# Creating /lost+found takes one inode and one data block. The inode was
# claimed FIRST (a bit set in the in-memory bitmap, dirty flag latched) and
# the block second -- so when the block allocation failed (full volume),
# the error return left the inode bit set with nothing behind it. The
# bitmap then flushed at exit, and the NEXT run read that bit as either a
# PHANTOM inode ("marked in use but its checksum is wrong", which
# repair_block()s everything) or, if a previously-freed number was picked,
# a RESURRECTED stale record (a brand-new orphan). fsck -r had
# manufactured the fault that stops fsck -r. The failure path now gives
# the inode number back.
#
# The full volume is forced with the CETRAFS_FSCK_LF_NO_BLOCK env knob
# (fsck-side, same pattern as devutil's CETRAFS_PEER_PROBE_SECS): filling
# a real volume to exactly zero free blocks is nondeterministic per run --
# allocation overheads shift -- and a flaky test here is worse than none.
#
# Discrimination: with the unwind removed from fsck_lost_found(), the
# follow-up run reports a fault the pre-repair run did not, and the
# "nothing new" assertions below fail. For the failed link,
# CETRAFS_FSCK_LF_UNDO_OFF leaves it all behind, in the suite.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper corrupt_poke)"

IMG="$(ct_image 560 lfnospc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lfnospc)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "setup: one orphan, with a FREED inode number below it"
# The freed low number is the load-bearing part: lost+found claims the
# FIRST free inode, and a number AHEAD of the orphan scan's cursor gets
# re-visited and self-freed within the same run, hiding the leak. A
# number BEHIND the cursor (this freed one) stays leaked on disk, where
# the next run reads the stale freed record as a brand-new orphan.
echo tmp >"$MNT/hole"
echo keepme >"$MNT/waif"
rm "$MNT/hole"
ROOT_INO="$(stat -c '%i' "$MNT")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
"$CPOKE" "$DEV" dirent "$ROOT_INO" waif >/dev/null # now it's an orphan
blockdev --flushbufs "$DEV"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "NO directory entry names it" &&
    pass "the orphan is reported" || fail "no orphan reported:
$OUT"

log "repair attempt with the block allocation forced to fail"
REP="$(CETRAFS_FSCK_LF_NO_BLOCK=1 ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$REP" | grep -q "no free block for /lost+found" &&
    pass "lost+found creation failed as forced" ||
    fail "expected 'no free block for /lost+found':
$REP"

# THE assertions: the failed creation must have given the claimed inode
# number back -- the follow-up run must report NOTHING the pre-repair run
# did not, in either of the two shapes the leak took.
AFTER="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$AFTER" | grep -q "marked in use but its checksum is wrong" &&
    fail "fsck -r manufactured a phantom inode (allocated bit, no record):
$(echo "$AFTER" | grep 'checksum is wrong')" ||
    pass "no phantom inode left behind by the failed lost+found creation"
BEFORE_ORPHANS="$(echo "$OUT" | grep -c "NO directory entry names it" || true)"
AFTER_ORPHANS="$(echo "$AFTER" | grep -c "NO directory entry names it" || true)"
[ "$AFTER_ORPHANS" -le "$BEFORE_ORPHANS" ] &&
    pass "no resurrected inode either ($AFTER_ORPHANS orphan(s) after, $BEFORE_ORPHANS before)" ||
    fail "the failed creation ADDED an orphan ($BEFORE_ORPHANS -> $AFTER_ORPHANS):
$(echo "$AFTER" | grep 'NO directory entry')"

# The same for a lost+found that was built but could not be linked into
# the root (audit 2026-11-15 BL-116): it held an inode, a live record
# and a block that nothing named, so every later run found one more
# directory no name reaches. Its control runs on a copy of the image.
log "repair attempt with the link into the root forced to fail"
COPY="$(ct_image 560 lfnospc-copy)"
blockdev --flushbufs "$DEV"
cp --sparse=always "$IMG" "$COPY"
CDEV="$(ct_loop "$COPY")"
REP="$(CETRAFS_FSCK_LF_NO_LINK=1 ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$REP" | grep -q "could not add /lost+found to the root directory" &&
    pass "the link of the new /lost+found failed as forced" ||
    fail "expected 'could not add /lost+found':
$REP"
AFTER="$(ct_fsck "$DEV" 2>&1 || true)"
AFTER_ORPHANS="$(echo "$AFTER" | grep -c "NO directory entry names it" || true)"
[ "$AFTER_ORPHANS" -le "$BEFORE_ORPHANS" ] && ! echo "$AFTER" | grep -qi "leak" &&
    pass "the unlinked /lost+found gave back its inode and its block ($AFTER_ORPHANS orphan(s), no leak)" ||
    fail "the failed link left something behind ($BEFORE_ORPHANS -> $AFTER_ORPHANS orphans):
$(echo "$AFTER" | grep -iE 'NO directory entry|leak')"
REP="$(CETRAFS_FSCK_LF_NO_LINK=1 CETRAFS_FSCK_LF_UNDO_OFF=1 ct_fsck_repair "$CDEV" 2>&1 || true)"
CAFTER="$(ct_fsck "$CDEV" 2>&1 || true)"
[ "$(echo "$CAFTER" | grep -c "NO directory entry names it" || true)" -gt "$BEFORE_ORPHANS" ] &&
    pass "control: without the undo, the unlinked /lost+found is left as one more orphan" ||
    fail "control: nothing was left behind without the undo -- the assertion above proves nothing"

log "control: with the knob off, the same repair succeeds"
REP2="$(ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$REP2" | grep -q "linked 1 orphaned inode" &&
    pass "the orphan is linked into /lost+found once a block is available" ||
    fail "repair did not recover the orphan with the knob off:
$REP2"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true # settle counters, as fsck itself asks
ct_fsck "$DEV" >/dev/null 2>&1 && pass "and the volume converges to clean" ||
    fail "no convergence after recovery: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -3)"

ct_exit
