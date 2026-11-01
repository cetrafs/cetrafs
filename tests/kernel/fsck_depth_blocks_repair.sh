#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an extent tree fsck cannot walk must stop `-r`, not cost the file its blocks
#
# fsck marks a block "referenced" by walking the owning inode's extent
# tree. An inode whose eh_depth is past what the format has is a tree
# this walker cannot descend -- so none of that file's blocks are ever
# marked, the leak pass sees them as owned by nobody, and `fsck -r`
# clears them from the data bitmap. The file IS the blocks.
#
# The bad-extent-magic case right above it in fsck.c already blocks
# repair for exactly this reason, with the reason spelled out in its
# message. The depth case counted the problem and carried on.
#
# Blocking repair is the conservative answer and the same one the
# neighbouring checks give: the volume is reported, nothing is written,
# and an operator decides.
#
# Discrimination: take the repair_block() call out and `fsck -r` reports
# repairs instead of refusing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fsckdepth)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckdepth)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

dd if=/dev/urandom of="$MNT/victim" bs=4096 count=64 status=none
sync
INO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"

# The setup must really have given the file blocks, or "its blocks were
# not cleared" is a claim about an empty set.
BLOCKS="$("$POKE" "$IMG" extents "$INO" | sed -n 's/.*blocks=\([0-9]*\).*/\1/p')"
[ -n "$BLOCKS" ] && [ "$BLOCKS" -ge 64 ] ||
    fail "the victim owns $BLOCKS blocks -- the setup did not arrange the situation"

ct_fsck "$DEV" >/dev/null || fail "the volume was not clean before the poke"

"$POKE" "$IMG" setdepth "$INO" 3 2>/dev/null

MAP="$(ct_helper bg_map)"
BEFORE_MAP="$("$MAP" "$IMG")"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
AFTER_MAP="$("$MAP" "$IMG")"
echo "$OUT" | grep -q "extent depth 3" &&
    pass "fsck reports the impossible depth" ||
    fail "fsck did not notice an extent depth of 3"

echo "$OUT" | grep -q "nothing repaired" &&
    pass "and repairing is refused rather than guessed at" ||
    fail "fsck -r went ahead: $(echo "$OUT" | grep -i repair | head -1)"

# And the proof it matters, read off the BITMAPS rather than the
# record: clearing a block as leaked raises its Block Group's free
# count, and the record's own blocks field would not move either way.
[ "$AFTER_MAP" = "$BEFORE_MAP" ] &&
    pass "no block changed hands: the Block Group free counts are identical" ||
    fail "the free counts moved, so blocks were cleared:
$(diff <(echo "$BEFORE_MAP") <(echo "$AFTER_MAP") | head -4)"

ct_exit
