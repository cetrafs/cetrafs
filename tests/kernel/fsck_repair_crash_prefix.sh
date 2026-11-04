#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every prefix of an fsck -r repair leaves a volume the kernel can trust
#
# fsck -r recovers an orphan by creating /lost+found -- an inode number,
# a dirent block, a record, a name in the root -- and naming the orphan
# there. The inode number's bitmap bit was set in memory and written
# back once, at the end of the namespace pass, AFTER the record and the
# dirents naming it; every write was buffered besides. A crash in that
# window left a directory entry naming an inode marked FREE, which the
# kernel then allocates again: two files, one record.
#
# Staged as fsck_lost_found.sh does (an orphan with a live link count,
# no /lost+found yet), then fsck -r is stopped dead after its 1st, 2nd,
# ... Nth repair write (CETRAFS_TEST_FSCK_STOP_AFTER_WRITES, _exit, no
# release), from the same starting image each time, until a run
# completes. After every stop a read-only fsck must not report a
# directory entry naming a FREE inode.
#
# What this cannot see: _exit loses nothing from the page cache, so it
# tests the ORDER of the writes, not their durability. That half -- the
# fdatasync after each repair write -- is the crash rig's to prove
# (tests/crash/).
#
# DISCRIMINATION: with the lost+found inode bit left for the end-of-pass
# write-back, a stop between the root's new entry and that write-back
# leaves "names inode N, which is marked FREE".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 fsckprefix)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckprefix)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/wanted" bs=4096 count=3 status=none
WANTED="$(stat -c '%i' "$MNT/wanted")"
ROOT_INO="$(stat -c '%i' "$MNT")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
"$CPOKE" "$DEV" dirent "$ROOT_INO" wanted >/dev/null
blockdev --flushbufs "$DEV"
TPL="$IMG.tpl"; ct_track file "$TPL"
cp --sparse=always "$IMG" "$TPL"

grep -q "inode $WANTED is allocated" <<<"$(ct_fsck "$DEV" 2>&1 || true)" ||
    { fail "setup: the orphan was not reported"; ct_exit; }
pass "setup: inode $WANTED is an orphan with a live link count, and there is no /lost+found"

reset_img() {
    dd if="$TPL" of="$IMG" bs=1M conv=notrunc,sparse status=none
    blockdev --flushbufs "$DEV"
}

BAD=0; N=0; DONE=0
while [ "$N" -lt 200 ]; do
    N=$((N + 1))
    reset_img
    RC=0
    CETRAFS_TEST_FSCK_STOP_AFTER_WRITES=$N "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || RC=$?
    [ "$RC" = 99 ] || { DONE=1; break; }
    # The stopped run left its repair claim; a real one would expire.
    "$NPOKE" "$IMG" 0 0 00 0 >/dev/null 2>&1
    blockdev --flushbufs "$DEV"
    OUT="$(ct_fsck "$DEV" 2>&1 || true)"
    if grep -q 'which is marked FREE' <<<"$OUT"; then
        fail "stopped after write $N: $(grep -m1 'marked FREE' <<<"$OUT")"
        BAD=$((BAD + 1))
    fi
done
[ "$DONE" = 1 ] || fail "setup: fsck -r never completed within 200 writes"
[ "$N" -gt 3 ] || fail "setup: the repair made only $((N - 1)) writes -- nothing to stop between"
[ "$BAD" = 0 ] && pass "every one of the $((N - 1)) stopping points left no entry naming a free inode"

# And the completed run did its job.
blockdev --flushbufs "$DEV"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $WANTED is allocated" <<<"$OUT" && fail "after the full repair the orphan is still reported" ||
    pass "the completed repair recovered the orphan"
ct_exit
