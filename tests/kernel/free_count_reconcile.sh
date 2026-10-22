#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# cached free-space counts are reconciled against the bitmaps
#
# Every free-space number this filesystem uses at runtime is a CACHE: a
# Block Group's free_data_blocks, the Zone Group aggregate rolled up
# from them, and the in-memory free-inode count. All are seeded once and
# maintained purely by increment and decrement. Nothing ever recomputed
# one from the bitmap that is the actual truth, so an unclean crash --
# which loses whatever deltas had accrued but not yet been applied --
# left them permanently wrong.
#
# Permanently is the word that matters. `statfs` reports the wrong
# figure for the life of the volume, and cetrafs_alloc_pick_bg() CHOOSES
# where to write on these numbers. P16 found the sharp end: a Zone Group
# whose aggregate had drifted to 0 was ranked last by every node's claim
# preference, so nobody claimed it, so nobody ever discovered the number
# was wrong -- the space was lost to the whole cluster.
#
# The repair runs at the one moment it is provably safe: when ownership
# of a Zone Group transfers to this node (a fresh claim, or a steal from
# a stale peer), and on re-attach at MOUNT, which is the "we crashed and
# came back" case. Never on a heartbeat tick, which would scan every
# owned bitmap every 15 seconds to find nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BGPOKE="$(ct_helper bg_poke)"
ZGPOKE="$(ct_helper zg_poke)"

IMG="$(ct_image 560 reconcile)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt reconcile)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

free_blocks() { stat -f -c '%f' "$MNT"; }

log "baseline: a healthy volume agrees with itself"
dd if=/dev/zero of="$MNT/payload" bs=4096 count=64 status=none
sync
BASE="$(free_blocks)"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "a healthy volume is fsck-clean before anything is broken" ||
    fail "the volume was already inconsistent: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

log "a BG count that drifted from its bitmap is corrected at mount"
# What an unclean crash leaves behind: the bitmap is the truth (it was
# written as blocks were allocated), the cached counter is whatever had
# been applied before the power went. Poked rather than crashed, because
# a loop device cannot lose power -- the two-node ctest scenario kills a
# node for real.
"$BGPOKE" "$IMG" 0 999999 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$OUT" | grep -qiE "free_data_blocks|bitmap says" &&
    pass "fsck detects the drifted BG counter (the control: the fault is really there)" ||
    fail "fsck did not report the poked counter, so this test would prove nothing: $(echo "$OUT" | head -3)"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "correcting (drift" &&
    pass "the mount logs the correction it made" ||
    fail "nothing was corrected at mount: $(dmesg_since "$MARK" | tail -3)"
NOW="$(free_blocks)"
[ "$NOW" = "$BASE" ] && pass "statfs reports the true free count again ($NOW)" ||
    fail "statfs reports $NOW, want $BASE -- the counter was not reconciled"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck is clean after the reconcile" ||
    fail "still inconsistent: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

log "P16's case: a ZG aggregate that drifted to 0 is repaired, not written off"
# The aggregate alone, with the BG counters left correct -- the exact
# shape that made a Zone Group permanently unclaimable.
"$ZGPOKE" "$IMG" 0 free 0 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$OUT" | grep -qiE "free_data_blocks|sum of" &&
    pass "fsck detects the drifted ZG aggregate" ||
    fail "fsck did not report the poked aggregate: $(echo "$OUT" | head -3)"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "but its Block Groups hold" &&
    pass "the mount recomputes the aggregate from its Block Groups" ||
    fail "the aggregate was not recomputed: $(dmesg_since "$MARK" | tail -3)"

# ...and the space is usable again, which is the point. A ZG reporting 0
# free is one no node will prefer to claim, so the blocks it really has
# are lost until something recomputes.
dd if=/dev/zero of="$MNT/after" bs=4096 count=32 status=none 2>/dev/null &&
    pass "the volume can still be written after the repair" || fail "a write failed after the repair"
sync
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck is clean after the aggregate repair" ||
    fail "still inconsistent: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

log "the repair does not run where it would be wrong or wasteful"
# A heartbeat tick re-attaches to every ZG this node already owns. If
# the reconcile ran there it would rescan every owned bitmap every 15
# seconds -- and, worse, it is pointless: nobody else can have touched
# a ZG we hold. The mount above corrected everything, so a tick must
# find nothing to say.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
sleep 20          # at least one heartbeat tick (15s)
dmesg_since "$MARK" | grep -q "correcting (drift" &&
    fail "a heartbeat tick is rescanning and correcting counters it cannot have broken" ||
    pass "a heartbeat tick does no reconcile work"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean at the end" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
