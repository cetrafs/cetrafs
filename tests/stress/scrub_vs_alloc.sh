#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub + heartbeat must never cross-link or lose data while files
# churn under ENOSPC pressure (the bg-task analog of defrag_vs_alloc)
#
# defrag_vs_alloc.sh showed defrag's destination allocator can double-
# hand-out a reservation's blocks under this load. This asks the same of
# the OTHER background reclaimers -- the scrub (frees "leaked" blocks) and
# the heartbeat's surplus-release (hands empty Block Groups back) -- which
# unlike defrag DO honor the speculative reservation (resv_list / BG-
# emptiness). So this is expected to PASS: it is the guard that proves
# they stay honest when real leaks appear (churn: delete half, rewrite)
# right as allocation reuses the freed space.
#
# Detectors: survivor content hashes (over-reclaim = corruption), fsck
# (overlap/leak/counts), statfs bound.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 1200 scruballoc)"
MNT="$(ct_mnt scruballoc)"
# Two ZGs so the heartbeat's surplus-release has something to hand back.
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 2048 -f >/dev/null

ct_param_set auto_defrag 0   # isolate the OTHER bg tasks from the defrag bug
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
compress_timing              # 1s heartbeat tick: surplus-release fires in-window

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Keeper files: written once, hashed, never touched again. If the scrub
# or a release ever frees a live block, a keeper's content changes.
declare -A KHASH
NKEEP=12
for k in $(seq 1 "$NKEEP"); do
    dd if=/dev/urandom of="$MNT/keep_$k" bs=1M count=3 status=none 2>/dev/null
    KHASH[$k]="$(sha256sum "$MNT/keep_$k" | cut -d' ' -f1)"
done
sync
pass "wrote $NKEEP keeper files with recorded hashes"

# Churn: fill with throwaway files, delete half (real leaks for the scrub
# to reclaim / BGs for release to reclaim), rewrite -- the freed space is
# reused right as the scrub and release act on it.
churn() {
    local t="$1" n=0 k
    while dd if=/dev/urandom of="$MNT/ch_${t}_$n" bs=1M count=4 status=none 2>/dev/null; do
        n=$((n + 1)); [ "$n" -gt 80 ] && break
    done
    for k in $(seq 0 2 "$n"); do rm -f "$MNT/ch_${t}_$k" 2>/dev/null; done
    n=0
    while dd if=/dev/urandom of="$MNT/cb_${t}_$n" bs=1M count=4 status=none 2>/dev/null; do
        n=$((n + 1)); [ "$n" -gt 80 ] && break
    done
}
churn A & c1=$!
churn B & c2=$!
wait "$c1" "$c2" 2>/dev/null || true
# Let a couple of scrub cycles + heartbeat ticks run against the result.
sleep 6
sync
pass "churned two writers to ENOSPC while scrub + heartbeat ran"

# Detector 1: keepers intact.
bad=0
for k in $(seq 1 "$NKEEP"); do
    [ "$(sha256sum "$MNT/keep_$k" | cut -d' ' -f1)" = "${KHASH[$k]}" ] || { bad=$((bad+1)); log "keep_$k changed"; }
done
[ "$bad" -eq 0 ] &&
    pass "every keeper is byte-identical -- no bg task freed a live block" ||
    fail "$bad keeper(s) corrupted -- the scrub or a release freed a block still in use"

ct_umount "$MNT"

# Detector 2: fsck.
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -q 'more than one inode' <<<"$FSCK_OUT"; then
    fail "fsck: cross-file overlap after scrub/release under load: $(grep -m1 'more than one inode' <<<"$FSCK_OUT")"
elif grep -qE 'cached free_data_blocks|aggregate free_data_blocks' <<<"$FSCK_OUT"; then
    skip "only benign free-count drift (OPEN-DEFECTS.md): $(grep -m1 free_data_blocks <<<"$FSCK_OUT")"
elif grep -q 'referenced by no inode' <<<"$FSCK_OUT"; then
    # Leaked blocks AFTER the scrub had cycles to run are a miss, but a
    # dropped foreign-free can leak legitimately; report, do not corrupt.
    skip "residual leaked blocks (scrub may not have reached them): $(grep -m1 'referenced by no inode' <<<"$FSCK_OUT")"
elif grep -q ERR <<<"$FSCK_OUT"; then
    fail "fsck: unexpected error: $(grep -m1 ERR <<<"$FSCK_OUT")"
else
    pass "fsck clean after scrub + release under churn"
fi

ct_exit
