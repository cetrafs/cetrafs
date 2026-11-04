#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free judges the Block Group's owner from the device, not a stale cache
#
# __cetrafs_free_data_extent() reads the owner of the extent's Block
# Group from its descriptor, cached on the first attempt. A BG owned by
# nobody makes the extent damage (a reference to unallocated blocks):
# counted as corruption, not freed, and under corruption=stop the mount
# stops. A BG this node last saw FREE -- in a statfs sweep -- and a peer
# then claimed and filled is exactly that on a stale cache: a live
# file's free refused as damage.
#
# Staged: BG 1 is FREE at mount, and statfs caches it so. Then, as a
# peer would, its descriptor is given an owner on the device; a file
# whose extent lies in it (planted before the mount, its bits set) is
# removed.
#
# DISCRIMINATION: judged from the cache, the free is refused as damage
# and the corruption count rises.
#
# NOT covered: the same re-read guards the other verdict, a foreign
# owner (the extent queued to that ZG's pending-free queue). That path
# needs atomic CAW, which a loop device does not have, and no ctest
# scenario stages it yet.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BGPOKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
LEAK="$(ct_helper data_leak_poke)"
PPOKE="$(ct_helper extent_phys_poke)"
FREE_MARK=65535

IMG="$(ct_image 1200 bgpeer)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgpeer)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/f" bs=4096 count=2 status=none
sync
FI="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"

# The file's two blocks, as a peer would have allocated them in BG 1.
OWNER1="$("$MAP" "$IMG" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
L="$("$LEAK" "$IMG" 1 0 2 | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
[ -n "$L" ] && [ -n "$OWNER1" ] && [ "$OWNER1" != "$FREE_MARK" ] ||
    { fail "setup: BG 1 (owner '$OWNER1') or its first data block ('$L') not found"; ct_exit; }
"$PPOKE" "$IMG" "$FI" "$L" >/dev/null
"$BGPOKE" "$IMG" 1 --owner "$FREE_MARK" >/dev/null
blockdev --flushbufs "$DEV"
# The file's original blocks in BG 0 are orphaned by the poke: that is
# the baseline the end state is measured against.
leaked() { { ct_fsck "$DEV" 2>&1 || true; } | sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode.*/\1/p'; }
L0="$(leaked)"; L0="${L0:-0}"

mount -t cetrafs -o corruption=stop "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
df "$MNT" >/dev/null # the sweep caches BG 1 as FREE
# A peer claims BG 1 (the bits are already set: its file is in there).
"$BGPOKE" "$IMG" 1 --owner "$OWNER1" >/dev/null
[ "$("$MAP" "$IMG" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')" = "$OWNER1" ] ||
    { fail "setup: BG 1's owner did not change on the device"; ct_exit; }
pass "setup: BG 1 cached FREE, owned by ZG $OWNER1 on the device, a file in it"

MARK="$(dmesg_mark)"
rm -f "$MNT/f"
sync
sleep 1
dmesg_since "$MARK" | grep -q "which no Zone Group owns" &&
    fail "the free was refused as damage from the stale FREE in the cache" ||
    pass "the free was not judged from the stale FREE"
[ "$(sed -n 's/^corruptions: //p' "$PROC")" = 0 ] && [ "$(sed -n 's/^stopped: //p' "$PROC")" = none ] &&
    pass "no corruption counted, the mount keeps going" ||
    fail "corruptions: $(sed -n 's/^corruptions: //p' "$PROC"), stopped: $(sed -n 's/^stopped: //p' "$PROC")"
ct_umount "$MNT"
# And the free happened: the file's two blocks are no longer in use.
# (Refused, they stay set with nothing naming them -- leaked.)
L1="$(leaked)"; L1="${L1:-0}"
[ "$L1" = "$L0" ] && pass "the file's blocks in BG 1 were freed (leaked: $L0 before, $L1 after)" ||
    fail "the file's blocks were not freed: leaked $L0 before the remove, $L1 after"
ct_exit
