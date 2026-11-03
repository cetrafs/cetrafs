#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an unmount whose final flush failed does not announce a clean departure
#
# Unmount flushed the free counts and the block device, ignored both
# results, never flushed the allocation bitmaps itself (sync_fs did, and
# the VFS ignores its result at unmount), and then marked the row
# departed. A departed row is reclaimable at once: a peer takes its Zone
# Groups and reconciles them from bitmaps missing this node's
# allocations. A flush failure now leaves the row to go stale, so it is
# reclaimed as a crashed node's instead.
#
# alloc_flush_fail makes the bitmap flush fail at every boundary. The
# block device sync still writes the buffer, so the volume stays
# consistent; what the test reads is the row's departure sentinel.
#
# DISCRIMINATION (measured on the old code): the row reads last_seen=0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/alloc_flush_fail ] || { skip "alloc_flush_fail is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 umflush)"
MNT="$(ct_mnt umflush)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing

log "control: a clean unmount announces its departure"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/a" bs=64k count=16 status=none
ct_umount "$MNT"
grep -q '^state=1 .*last_seen=0 ' <<<"$("$NODE_POKE" "$DEV" 0)" &&
    pass "control: row 0 departed cleanly" ||
    { fail "control: a clean unmount did not mark the row departed: $("$NODE_POKE" "$DEV" 0)"; ct_exit; }

log "the allocation bitmap cannot be flushed at unmount"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
ct_param_set alloc_flush_fail 1
dd if=/dev/urandom of="$MNT/b" bs=64k count=16 status=none 2>/dev/null || true
umount "$MNT"
ct_param_set alloc_flush_fail 0
grep -q "allocation bitmap not made durable" <<<"$(dmesg_since "$MARK")" &&
    pass "setup: the bitmap flush failed" ||
    { fail "setup: the injected bitmap flush failure never fired"; ct_exit; }
ROW="$("$NODE_POKE" "$DEV" 0)"
grep -q '^state=1 ' <<<"$ROW" || { fail "setup: row 0 is not registered: $ROW"; ct_exit; }
grep -q ' last_seen=0 ' <<<"$ROW" &&
    fail "row 0 was marked departed although the flush failed -- a peer would reclaim it at once: $ROW" ||
    pass "row 0 was left to go stale, not announced as a clean departure"

log "the node comes back"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
pass "remounted"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -iE 'err|fault' | head -3)"
ct_exit
