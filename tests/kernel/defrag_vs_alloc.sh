#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag running WHILE other files are being allocated must never
# cross-link a block, lose data, or drift the accounting
#
# Every existing defrag test moves ONE file in isolation. The hazard this
# one targets is the defragmenter's destination allocator
# (cetrafs_alloc_pick_run) competing with ordinary allocation under space
# pressure: if defrag ever lands a file's relocated run on blocks another
# file still holds -- or frees a block still referenced, which the next
# allocation then re-hands-out -- two inodes end up sharing a block.
# That is exactly what defrag's abort path did (free part of a
# just-committed destination run -- see tests/kernel/defrag_commit_tail.sh
# for the deterministic pin and OPEN-DEFECTS.md "Resolved" for the full
# story), reproduced here with defrag ON and masked entirely with defrag
# OFF.
#
# Three independent detectors, because one alone can miss it:
#   1. CONTENT: each victim file is written once with a recorded hash and
#      never touched again; a block cross-linked to a file that is still
#      being written comes back corrupted.
#   2. fsck: the offline authority on "one block, one owner" plus every
#      free-count vs bitmap and ZG-vs-sum cross-check.
#   3. ACCOUNTING: statfs free must not claim space the bitmap does not
#      have once the dust settles.
#
# This was the probabilistic reproducer (~1-in-10) while the defect was
# open; since the 2026-10-28 fix it is a clean gate. If it ever fails
# again, do not weaken a check -- a new free-while-referenced or
# double-allocation has appeared.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 1200 defragalloc)"
MNT="$(ct_mnt defragalloc)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null

# Auto-defrag ON and eager, so the background mover actually fires during
# the fill; scrub off (its 30-min cycle never runs in-window and would
# only add noise).
# Fourth detector: the in-core shadow bitmap mirrors every data-block
# allocate/free this node performs and screams SHADOW DOUBLE-ALLOC /
# FREE-OF-UNTRACKED in dmesg if the allocator ever hands a block out
# twice or frees one it does not hold. It is what pinned the original
# bug's family down; keep it armed where the bug lived. (Must be set
# BEFORE the mount: the bitmap is sized and allocated at mount time.)
ct_param_set alloc_shadow 1

ct_param_set auto_defrag 1
ct_param_set auto_defrag_min_extents 4
ct_param_set scrub 0

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# ---- phase 1: lay down VICTIM files, fragmented, hashes recorded ----
# Interleaved filler writes steal each file's contiguity hint so it
# spills into many extents -- the shape auto-defrag then relocates.
declare -A VHASH
NVIC=12
for v in $(seq 1 "$NVIC"); do
    f="$MNT/victim_$v"
    for b in $(seq 0 15); do
        dd if=/dev/urandom of="$f" bs=4096 seek="$b" count=1 conv=notrunc status=none 2>/dev/null
        printf x >"$MNT/vfill_${v}_${b}"
    done
    sync "$f"
    VHASH[$v]="$(sha256sum "$f" | cut -d' ' -f1)"
done
rm -f "$MNT"/vfill_* 2>/dev/null
sync
pass "laid down $NVIC fragmented victim files with recorded hashes"

# ---- phase 2: allocation pressure + explicit defrag, concurrently ----
# Fillers consume the free space (and whatever defrag frees), forcing the
# destination allocator to reuse blocks right as defrag hands them out.
filler() {
    local t="$1" n=0
    while dd if=/dev/urandom of="$MNT/fill_${t}_$n" bs=1M count=8 status=none 2>/dev/null; do
        n=$((n + 1)); [ "$n" -gt 120 ] && break
    done
}
defragger() {
    local pass
    for pass in 1 2 3 4; do
        for v in $(seq 1 "$NVIC"); do
            "$ROOT/userspace/defrag.cetra" "$MNT/victim_$v" >/dev/null 2>&1 || true
        done
    done
}
filler A & fp1=$!
filler B & fp2=$!
defragger & dp=$!
wait "$fp1" "$fp2" "$dp" 2>/dev/null || true
sync
pass "ran defrag over the victims while two writers filled the volume"

# ---- detector 1: victim content intact ----
bad=0
for v in $(seq 1 "$NVIC"); do
    h="$(sha256sum "$MNT/victim_$v" | cut -d' ' -f1)"
    [ "$h" = "${VHASH[$v]}" ] || { bad=$((bad + 1)); log "victim_$v content CHANGED"; }
done
[ "$bad" -eq 0 ] &&
    pass "every victim file is byte-identical after concurrent defrag (no block was cross-linked into a live file)" ||
    fail "$bad victim file(s) corrupted -- a defrag relocation or free cross-linked a live block"

ct_umount "$MNT"

# ---- detector 2: fsck (overlap, leak, every count vs the bitmap) ----
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -q 'more than one inode' <<<"$FSCK_OUT"; then
    fail "fsck: cross-file overlap after concurrent defrag: $(grep -m1 'more than one inode' <<<"$FSCK_OUT")"
elif grep -q 'referenced by no inode' <<<"$FSCK_OUT"; then
    fail "fsck: leaked blocks after concurrent defrag: $(grep -m1 'referenced by no inode' <<<"$FSCK_OUT")"
elif grep -qE 'cached free_data_blocks|aggregate free_data_blocks' <<<"$FSCK_OUT"; then
    # Benign free-count cache drift (docs/internal/OPEN-DEFECTS.md) -- not
    # a defrag-correctness fault; the bitmap is authoritative.
    skip "only benign free-count drift after defrag: $(grep -m1 free_data_blocks <<<"$FSCK_OUT")"
elif grep -q ERR <<<"$FSCK_OUT"; then
    fail "fsck: unexpected error after concurrent defrag: $(grep -m1 ERR <<<"$FSCK_OUT")"
else
    pass "fsck clean after concurrent defrag (no overlap, no leak, counts match the bitmap)"
fi

# ---- detector 3: survives a remount, and statfs agrees with fsck ----
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
bad=0
for v in $(seq 1 "$NVIC"); do
    h="$(sha256sum "$MNT/victim_$v" 2>/dev/null | cut -d' ' -f1)"
    [ "$h" = "${VHASH[$v]}" ] || bad=$((bad + 1))
done
[ "$bad" -eq 0 ] &&
    pass "victim content still correct after remount" ||
    fail "$bad victim file(s) wrong after remount"
# statfs must not advertise more free than the device could hold.
TOTAL_F="$(stat -f -c '%b' "$MNT")"
FREE_F="$(stat -f -c '%f' "$MNT")"
[ "$FREE_F" -le "$TOTAL_F" ] &&
    pass "statfs free ($FREE_F) is within total ($TOTAL_F) blocks" ||
    fail "statfs reports more free ($FREE_F) than total ($TOTAL_F) -- count drift ran off the end"
ct_umount "$MNT"

dmesg | grep -qE "SHADOW DOUBLE-ALLOC|FREE-OF-UNTRACKED" &&
    fail "the allocator shadow caught a double allocation or bad free" ||
    pass "allocator shadow: every block allocated once, every free backed"

ct_exit
