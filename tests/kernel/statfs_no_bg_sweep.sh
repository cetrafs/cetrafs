#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# statfs must not sweep every Block Group descriptor
#
# statfs used to read all block_group_count descriptors and force every
# one this node does not own back to the device, because a peer's writes
# are invisible in our cache. On the deployment volume that is 2047 BGs
# of which the node owns 127, so each statfs issued ~1920 synchronous
# 4 KiB reads -- and pvestatd polls statfs on every storage every ~10 s.
#
# Free space now comes from the Zone Group aggregates instead: the same
# number (alloc.c rolls the same delta into both, both are applied by CAS
# at the same boundaries, and fsck cross-checks ZG == sum of its BGs)
# read from zone_group_count records rather than block_group_count.
#
# procfs "info" still sweeps, which is what makes this observable: a
# counter read costs one sweep, so take a baseline over zero statfs calls
# and compare it against the same window with many.
#
# Discrimination: put the per-BG loop back in cetrafs_statfs() and the
# second window grows by one sweep per statfs call, failing the assert.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 2048 nosweep)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nosweep)"
ct_mkfs "$DEV" -z 4 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# This suite observes statfs THROUGH procfs info, whose foreign-BG
# sweep is rate-limited in production. Pin it off so the counters move
# on every read -- otherwise the test is blind, not passing.
ct_param_set bg_sweep_min_secs 0
PROC="$(ct_procdir "$DEV")/info"
swept() { sed -n 's/^bg_desc_refreshed: //p' "$PROC"; }

[ -n "$(swept)" ] || fail "procfs has no bg_desc_refreshed counter"

# Baseline: the cost of two counter reads with NO statfs between them.
A="$(swept)"; B="$(swept)"
BASE=$((B - A))
[ "$BASE" -gt 0 ] || fail "procfs info is not sweeping -- this test cannot observe anything"

# Same window, but with 10 statfs calls in the middle.
C="$(swept)"
for _ in $(seq 1 10); do stat -f "$MNT" >/dev/null; done
D="$(swept)"
WITH=$((D - C))

log "descriptor refreshes: $BASE with no statfs, $WITH with 10 statfs"

[ "$WITH" -eq "$BASE" ] ||
    fail "10 statfs calls cost $((WITH - BASE)) extra descriptor refreshes -- statfs is still sweeping"

# It must still report the truth. Write 64 MiB and watch free space fall
# by roughly that much (allow slack for metadata).
FREE0="$(stat -f -c %f "$MNT")"
dd if=/dev/zero of="$MNT/f" bs=1M count=64 conv=fsync status=none
sync
FREE1="$(stat -f -c %f "$MNT")"
USED=$((FREE0 - FREE1))
log "free blocks fell by $USED after a 64 MiB (16384 block) write"
[ "$USED" -ge 16384 ] && [ "$USED" -lt 17000 ] ||
    fail "statfs free-space accounting is wrong: 16384 blocks written, df moved by $USED"

# And the total must be sane and stable.
T0="$(stat -f -c %b "$MNT")"
[ "$T0" -gt 0 ] || fail "statfs reports zero total blocks"
rm -f "$MNT/f"; sync
T1="$(stat -f -c %b "$MNT")"
[ "$T0" = "$T1" ] || fail "total block count changed ($T0 -> $T1); capacity is fixed at mkfs"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults (ZG aggregates disagree with the bitmaps?)"

pass "statfs answers from the ZG aggregates without sweeping BG descriptors"

ct_exit
