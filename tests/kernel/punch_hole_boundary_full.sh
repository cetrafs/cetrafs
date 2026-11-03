#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch whose partial boundary blocks are holes succeeds on a full volume
#
# A punch zeroes the partial blocks at its two ends through the write
# path. When such a block was a hole (or preallocated and never
# written), write_begin ALLOCATED it in order to write zeroes into it --
# so a punch, which only gives space back, failed with ENOSPC on a full
# volume. A guest's TRIM is exactly that request. A hole already reads
# as zeroes; it is now skipped.
#
# DISCRIMINATION: without the change the punch fails ENOSPC.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 punchfull)"
MNT="$(ct_mnt punchfull)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Data in blocks 0 and 8; blocks 1..7 a hole.
printf 'A%.0s' $(seq 1 4096) | dd of="$MNT/s" bs=4096 seek=0 count=1 conv=notrunc status=none
printf 'B%.0s' $(seq 1 4096) | dd of="$MNT/s" bs=4096 seek=8 count=1 conv=notrunc status=none
sync
SUM0="$(md5sum <"$MNT/s")"
dd if=/dev/zero of="$MNT/fill" bs=1M status=none 2>/dev/null || true
sync
if dd if=/dev/zero of="$MNT/probe" bs=4096 count=1 conv=fsync status=none 2>/dev/null; then
    fail "setup: the volume still takes a block -- not full"
    ct_exit
fi
pass "setup: the volume is full, and s has a hole over blocks 1..7"

# Ends at 4096+100 and 3*4096+50: both partial, both inside the hole.
if OUT="$(fallocate -p -o $((4096 + 100)) -l $((2 * 4096 - 50)) "$MNT/s" 2>&1)"; then
    pass "a punch with both boundaries in the hole succeeds on a full volume"
else
    fail "the punch failed: $OUT"
fi
[ "$(md5sum <"$MNT/s")" = "$SUM0" ] && pass "s reads exactly as before (the hole was already zeroes)" ||
    fail "s changed"
log "control: a boundary inside DATA is still zeroed"
fallocate -p -o 100 -l 50 "$MNT/s"
[ "$(dd if="$MNT/s" bs=1 skip=100 count=50 status=none | tr -d '\0' | wc -c)" = 0 ] &&
    [ "$(dd if="$MNT/s" bs=1 skip=99 count=1 status=none)" = A ] &&
    pass "control: a partial punch of a data block zeroes exactly its range" ||
    fail "control: the data block's partial punch was not applied"
ct_exit
