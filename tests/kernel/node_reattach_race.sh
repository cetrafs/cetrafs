#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Registry re-attach vs a racing fence: the bump must SURVIVE the take-back
#
# A remounting node re-attaches to the registry row that already carries its
# UUID. That take-back used to be a blind write of the row as read moments
# earlier -- and the one legitimate foreign writer of our row is a peer's
# fence_epoch bump (a CAS, fired the moment the peer starts reclaiming a
# stale node's journal/ZGs/locks). A bump landing between the re-attach's
# read and its write was silently REVERTED, and the local fence lease was
# baselined from the same stale read: the peer went on replaying our journal
# and stealing our ZGs believing us fenced, while we came up live, unfenced
# and writing. The take-back is now a CAS that preserves fence_epoch and
# baselines from the image the swap actually committed.
#
# A real peer cannot be timed into that window from a script, so the
# reattach_race_bump knob injects the bump at the exact spot: after the
# registration scan's read, before the re-attach swap (restored at ct_exit).
# With the CAS the bump survives (fence_epoch reads 1 afterwards) and is
# inherited as a pre-join bump (the node comes up writable, not fenced);
# with the old blind write it read 0 -- the fence signal destroyed -- which
# is exactly the assertion below, so this suite discriminates.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 reattach)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt reattach)"
ct_mkfs_small "$DEV" -M 4 >/dev/null

row0_field() { # field name -> value
    "$POKE" "$DEV" 0 | sed -n "s/.*$1=\([0-9]*\).*/\1/p"
}

log "first mount claims row 0; clean unmount leaves it re-attachable"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
: >"$MNT/seed"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
[ "$(row0_field fence_epoch)" = 0 ] && pass "baseline: row 0 fence_epoch is 0 after the first session" ||
    fail "baseline wrong: fence_epoch=$(row0_field fence_epoch) before the race is even injected"

log "re-attach with a reclaimer's fence bump injected mid-take-back"
ct_param_set reattach_race_bump 1
mount -t cetrafs "$DEV" "$MNT"
ct_param_set reattach_race_bump 0
require_cetrafs_mount "$MNT"
# Inherited as a pre-join bump: the fresh incarnation must NOT self-fence
# over an epoch it was born with.
: >"$MNT/proof"
[ -e "$MNT/proof" ] && pass "the re-attached node is writable (the inherited bump did not fence the fresh join)" ||
    fail "re-attached but not writable -- the inherited epoch fenced its own fresh join"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"

# THE assertion: the racing bump SURVIVED the take-back. The blind-write
# re-attach republished the pre-bump row image, and this read 0.
EPOCH="$(row0_field fence_epoch)"
[ "$EPOCH" = 1 ] && pass "the racing fence bump survived the re-attach (fence_epoch=1 on disk)" ||
    fail "fence_epoch=$EPOCH after the raced re-attach -- the fence signal was reverted (expected 1)"

log "control: a quiet re-attach neither loses nor invents bumps"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
[ "$(row0_field fence_epoch)" = 1 ] && pass "fence_epoch still 1 after an unraced remount (preserved, not re-bumped)" ||
    fail "fence_epoch=$(row0_field fence_epoch) after a quiet remount -- a re-attach must not change it"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
