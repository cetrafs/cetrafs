#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r repairs what it can derive, and refuses what it cannot
#
# Until now every fault fsck found was one the operator fixed by
# reformatting -- which, for a SAN volume holding other people's VM
# images, is not an answer anyone accepts.
#
# What -r fixes is exactly the set that is MECHANICALLY DERIVABLE from
# data the filesystem still holds, where there is one right answer and
# no judgement: a bitmap bit disagreeing with the extent trees in either
# direction, a cached free count disagreeing with the bitmap it
# summarises, and an nlink disagreeing with the entries that name it.
# That is the residue an unclean crash leaves.
#
# What it must NEVER do is guess. Cross-file overlap has no derivable
# answer -- nothing on disk says which inode should keep the block --
# and an inode whose record or extent header is unreadable hides its
# blocks from the walk, so every one of them LOOKS leaked. Clearing
# those would hand a live file's blocks to the allocator: a readable
# corruption turned into cross-file corruption by the repair tool. So
# repair refuses entirely when it meets a fault in that class.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper corrupt_poke)"
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 repair)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt repair)"

build() {
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir -p "$MNT/a/b"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=40 status=none
    ln "$MNT/f" "$MNT/f2"
    SUM="$(md5sum <"$MNT/f")"
    FREE="$(stat -f -c '%f' "$MNT")"
    sync
    ct_umount "$MNT"
}

log "a healthy volume: -r must be silent and change nothing"
# The cries-wolf check, and the one N5 is about. A repair tool that
# "fixes" a correct volume is worse than no repair tool.
build
OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "cetrafs fsck: OK" && pass "fsck -r reports a healthy volume clean" ||
    fail "fsck -r reported problems on a healthy volume: $(echo "$OUT" | grep -i err | head -2)"
echo "$OUT" | grep -q "repaired" && fail "fsck -r claims to have repaired a healthy volume" ||
    pass "fsck -r repaired nothing on a healthy volume"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "...and the volume is still clean afterwards" ||
    fail "fsck -r damaged a healthy volume"

log "the crash residue: a leaked block, a block marked free, a wrong link count"
build
"$CPOKE" "$IMG" bitset 0 900 >/dev/null     # marked used, nothing references it
"$CPOKE" "$IMG" bitclr 0 1 >/dev/null       # referenced, marked free -- handed out twice
"$IPOKE" "$IMG" nlink 1 9 >/dev/null        # root's link count
BEFORE="$(ct_fsck "$DEV" 2>&1 | grep -cE '^(ERR|WARN)' || true)"
[ "$BEFORE" -ge 3 ] && pass "the three faults are all detected before the repair ($BEFORE reports)" ||
    fail "only $BEFORE reports -- the image is not in the state this test needs"

OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "repaired" && pass "fsck -r reports what it repaired" ||
    fail "fsck -r repaired nothing: $(echo "$OUT" | tail -3)"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "the volume is clean after one repair pass" ||
    fail "still reporting after the repair: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -3)"

log "...and the repaired volume is still a working filesystem"
# A repair that produces a clean fsck and an unusable volume has made
# things worse, so the content is checked, not just the checker.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(md5sum <"$MNT/f")" = "$SUM" ] && pass "the file's contents are byte-identical after the repair" ||
    fail "the file's contents changed"
[ "$(stat -c '%h' "$MNT/f")" = "2" ] && pass "the hardlinked file still reports 2 links" ||
    fail "nlink is $(stat -c '%h' "$MNT/f")"
[ "$(stat -c '%h' "$MNT")" = "3" ] && pass "root's link count was corrected to match its one subdirectory" ||
    fail "root nlink is $(stat -c '%h' "$MNT")"
[ -d "$MNT/a/b" ] && pass "the directory tree survived" || fail "the tree is gone"
[ "$(stat -f -c '%f' "$MNT")" = "$FREE" ] && pass "free space matches what it was before the corruption" ||
    fail "free space is $(stat -f -c '%f' "$MNT"), was $FREE"
: >"$MNT/after-repair" && pass "the volume still accepts new files" || fail "a write failed after the repair"
ct_umount "$MNT"

log "a fault with no derivable answer must stop the repair ENTIRELY"
# Cross-file overlap, alongside a leak that WOULD be repairable on its
# own. The leak must survive: those blocks only look leaked because the
# corrupt extent trees hide them, and clearing them would give a live
# file's blocks back to the allocator.
build
ct_mount "$DEV" "$MNT"; INO="$(stat -c '%i' "$MNT/f")"; ct_umount "$MNT"
"$CPOKE" "$IMG" bitset 0 901 >/dev/null
"$CPOKE" "$IMG" extent "$INO" 9000 >/dev/null
"$CPOKE" "$IMG" extent 2 9000 >/dev/null
OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "NOTE: repair is disabled" &&
    pass "fsck -r says why it will not repair a volume with cross-file overlap" ||
    fail "no refusal note: $(echo "$OUT" | tail -3)"
echo "$OUT" | grep -q "nothing repaired" && pass "...and reports that it changed nothing" ||
    fail "it did not say it changed nothing: $(echo "$OUT" | tail -2)"
AFTER="$(ct_fsck "$DEV" 2>&1 | grep -c "leaked" || true)"
[ "$AFTER" -ge 1 ] &&
    pass "the blocks that merely LOOK leaked were left alone (clearing them would corrupt a live file)" ||
    fail "the repair cleared blocks on a volume it did not understand"

log "a record it cannot read must stop the repair too"
# An unreadable inode is skipped by the walk, so every block it owns
# looks leaked. This is the dangerous case: the one where repairing
# would turn a contained fault into cross-file corruption.
build
"$IPOKE" "$IMG" corrupt 3 >/dev/null 2>&1 || "$IPOKE" "$IMG" nlink 3 1 >/dev/null
OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
if echo "$OUT" | grep -q "checksum is wrong"; then
    echo "$OUT" | grep -q "NOTE: repair is disabled" &&
        pass "fsck -r refuses to repair around an inode record it cannot read" ||
        fail "it repaired around an unreadable record: $(echo "$OUT" | tail -3)"
else
    skip "the poke did not produce an unreadable record on this image"
fi

ct_exit
