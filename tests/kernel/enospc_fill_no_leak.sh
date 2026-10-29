#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# filling a volume to ENOSPC must leave NO leaked blocks (the file-domain
# shadow lost-update, fixed 2026-10-27 -- was OPEN-DEFECTS.md #1)
#
# A regular file's hot write path (cetrafs_get_block) does not publish
# its extent-tree updates to the device per block -- it stages them in an
# in-core "file-domain shadow" and publishes at a durability boundary
# (writeback, close, fsync). Every file-path read overlays that shadow so
# the mapping sees the extents already handed out.
#
# The bug: the publisher (->write_inode on writeback) cleared the shadow's
# dirty flag the instant it SNAPSHOTTED the shadow, before its CAS to the
# device had landed. A get_block landing in that window found dirty=false,
# so its overlay was a no-op: it rebuilt the file's tree from the LAGGING
# device record (still the pre-writeback, near-empty tree), appended one
# block, and staged that tiny tree back -- dropping every extent allocated
# since the snapshot from the shadow. Those blocks stay set in the bitmap
# (the allocator set them) but are referenced by no inode: leaked.
#
# That is the benign DIRECTION of the race (a lost reference leaks space,
# which the scrub/fsck reclaim). The same lost update in the other
# direction -- a published record keeping an extent whose block is later
# reused -- is the cross-file overlap this defect opened with. Both are
# the same window; this fills to ENOSPC, the condition that made it
# measurable, and asserts the bitmap and the inodes agree.
#
# The fix: take no longer clears dirty; the publisher reports the seq it
# published and the flag clears only if nothing staged since, and every
# publisher of the file sector (writeback and the rebuild paths) runs
# under a per-inode mutex.
#
# The leak needs the publisher (->write_inode) to run WHILE get_block is
# still appending to the same file. Background writeback does that on its
# own timer, but how often it fires during one fill depends on the box's
# speed and load -- on a fast loop device the whole fill finishes in two
# seconds and every publish defers to the closing sync, so the window is
# never hit and the test passes vacuously. To force it on demand the
# suite runs a tight `sync` loop alongside the writer: each sync drives
# write_inode on the growing file, concurrent with its get_block.
#
# Negative control: fd_take_clears_dirty=1 restores the clear-at-take and
# the same fill leaks -- asserted below, so a pass against code that
# stopped leaking (or stopped filling) for some unrelated reason is not
# mistaken for the fix.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# One 512 MiB Block Group is the smallest this filesystem formats, and
# the leak only shows once writeback runs DURING a sustained fill -- so
# the volume must be big enough that filling it spans many writeback
# ticks. Two BGs over ~1.2 GiB, kept off /tmp.
DEV="$(ct_big_dev 1200 enospcleak)"
MNT="$(ct_mnt enospcleak)"

leaked_count() {
    ct_fsck "$1" 2>&1 |
        sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode.*/\1/p' |
        head -1
}
overlap_count() { ct_fsck "$1" 2>&1 | grep -c "more than one inode" || true; }

# Fill to ENOSPC with one writer (8 MiB files until dd fails for space),
# a concurrent `sync` loop forcing write_inode to race the appends.
fill_to_enospc() {
    local mnt="$1" n=0
    ( while :; do sync; done ) &
    local syncpid=$!
    while dd if=/dev/urandom of="$mnt/f_$n" bs=1M count=8 status=none 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -gt 400 ] && break
    done
    kill "$syncpid" 2>/dev/null || true
    wait "$syncpid" 2>/dev/null || true
    echo "$n"
}

# run_fill -> echoes "<files> <leaked> <overlap>" with the volume freshly
# made, filled, unmounted, and fsck'd, under whatever fd_take_clears_dirty
# the caller set. Leaves nothing mounted. Runs in a subshell (process
# substitution), so it must not touch the module param -- see the call
# sites.
run_fill() {
    ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    local files lk ov
    files="$(fill_to_enospc "$MNT")"
    sync
    ct_umount "$MNT"
    lk="$(leaked_count "$DEV")"; lk="${lk:-0}"
    ov="$(overlap_count "$DEV")"; ov="${ov:-0}"
    echo "$files $lk $ov"
}

# ---- the fix: filling leaves nothing leaked ----
# Set the knob in the PARENT shell (run_fill runs in a subshell), so its
# restore is tracked and ct_exit puts it back.
ct_param_set fd_take_clears_dirty 0
read -r FILES LK OV < <(run_fill)
LK="${LK:-0}"
[ "$FILES" -ge 40 ] &&
    pass "fill reached ENOSPC after $FILES files (writeback ran many times mid-fill)" ||
    fail "only $FILES files before stopping -- too few to exercise writeback; test would be vacuous"
[ "$LK" -eq 0 ] &&
    pass "no leaked blocks after fill-to-ENOSPC (shadow lost-update fixed)" ||
    fail "$LK blocks leaked after fill -- the shadow lost-update is back"
[ "$OV" -eq 0 ] &&
    pass "no cross-file block overlap after fill" ||
    fail "$OV cross-file overlap(s) -- a block is referenced by two inodes"

# ---- the negative control: restore the bug, the leak returns ----
ct_param_set fd_take_clears_dirty 1
read -r BUG_FILES BUG_LK BUG_OV < <(run_fill)
BUG_LK="${BUG_LK:-0}"
[ "$BUG_LK" -gt 0 ] &&
    pass "negative control: with the bug restored the fill leaks $BUG_LK blocks (the check discriminates)" ||
    fail "negative control: fill leaked nothing with fd_take_clears_dirty=1 -- the test cannot catch the regression"
ct_param_set fd_take_clears_dirty 0

ct_exit
