#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory growth that fails after its leaf was journaled does not free the new block
#
# Growing a depth-1 directory allocates a block, initialises it, appends
# its extent to the leaf -- through the journal -- and then writes the
# record. When the leaf's target write failed, the journal entry stayed
# LIVE on purpose (a later replay redoes it), and get_block then freed the
# block anyway: the replay put a leaf naming a FREE block back on the
# device, which the allocator hands to the next file. Rule 8 -- a free
# may not follow a publish whose outcome is unknown. The block now stays
# allocated; a block nothing ends up naming is a leak the scrub reclaims.
#
# journal_fail_target_write refuses the leaf's target write and keeps the
# entry live; the remount replays it; fsck then judges the device.
#
# DISCRIMINATION (measured with the free put back): fsck reports the new
# block referenced by an inode but marked FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAF_CHECK="$(ct_helper blk_tail_poke)"
IMG="$(ct_image 560 dgf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dgf)"
# A real journal: the leaf goes through it only when there is one.
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 4096 -f >/dev/null
ct_param_set auto_defrag 0
ct_param_set alloc_run_blocks 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A depth-1 directory: its blocks must not be contiguous, so a one-block
# file takes the next block every time the directory grows.
# Fixed-width names, so every block holds the same number of entries.
name() { printf 'entry_with_a_reasonably_long_name_%06d' "$1"; }
mkdir "$MNT/d"
DINO="$(stat -c %i "$MNT/d")"
n=0
PER_BLOCK=0
for round in $(seq 1 8); do
    b0="$(stat -c %b "$MNT/d")"
    k=0
    while [ "$(stat -c %b "$MNT/d")" = "$b0" ]; do
        : >"$MNT/d/$(name "$n")"
        n=$((n + 1))
        k=$((k + 1))
    done
    # The entry that grew it went into the new block: a full block holds
    # one fewer than were created since the last growth (from round 2 on,
    # the previous round's growing entry is already in the block).
    [ "$round" = 2 ] && PER_BLOCK="$k"
    dd if=/dev/zero of="$MNT/spacer$round" bs=4096 count=1 conv=fsync status=none
done
sync
umount "$MNT"
"$LEAF_CHECK" "$DEV" leaf "$DINO" check >/dev/null 2>&1 ||
    { fail "setup: directory ino $DINO is not depth 1 after $n entries -- the leaf path is not exercised"; ct_exit; }
pass "setup: directory ino $DINO is depth 1 ($n entries)"
ct_mount "$DEV" "$MNT"

# Fill the last block (it holds the entry that grew it), so the next
# create has to grow the directory.
[ "$PER_BLOCK" -gt 1 ] || { fail "setup: could not measure entries per block ($PER_BLOCK)"; ct_exit; }
for i in $(seq 2 "$PER_BLOCK"); do
    : >"$MNT/d/$(name "$n")"
    n=$((n + 1))
done
b0="$(stat -c %b "$MNT/d")"

log "the leaf's target write fails while the directory grows"
MARK="$(dmesg_mark)"
ct_param_set journal_fail_target_write 1
failed=0
: >"$MNT/d/$(name "$n")" 2>/dev/null || failed=1
ct_param_set journal_fail_target_write 0
[ "$failed" = 1 ] && [ "$(stat -c %b "$MNT/d")" = "$b0" ] ||
    { fail "setup: the create did not fail, or the directory grew anyway -- the growth path was not reached"; ct_exit; }
dmesg_since "$MARK" | grep -E 'journal_fail_target_write set' | head -2
pass "setup: a directory growth failed on the leaf's target write"

# The entry is still live: a remount replays it.
umount "$MNT"
ct_mount "$DEV" "$MNT"
umount "$MNT"

OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q '^cetrafs fsck:' || { echo "$OUT" | tail -3; fail "setup: fsck did not complete"; ct_exit; }
if echo "$OUT" | grep -q 'referenced by an inode but marked FREE'; then
    fail "the replayed leaf names a block the failed growth had freed"
    echo "$OUT" | grep 'marked FREE' | head -3
else
    pass "no block named by the replayed leaf is FREE"
fi

ct_exit
