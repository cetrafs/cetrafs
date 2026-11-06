#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write that arrives while the surplus release has its space drained waits, not ENOSPC
#
# Each heartbeat tick hands back empty Block Groups (and surplus Zone
# Groups). To do it safely it first drains them -- takes them out of the
# allocator's reach -- then flushes, checks and either gives them back or
# undrains them. An allocation that found no space while that ran
# returned ENOSPC, although the space came back (or became claimable) an
# instant later: a write failing on a volume with room, which for a VM
# image is a guest I/O error. Found while staging the Zone Group claim
# race of audit 2026-11-06 M4.
#
# Staged: one Zone Group, Block Group 0 full, Block Group 1 owned and
# empty. A tick's release drains 1 and bg_release_drain_stall_ms holds it
# there; a write starts inside the hold. It must succeed.
#
# DISCRIMINATION: without the allocator's wait on the release
# (cetrafs_sb_release_wait()) the write fails with ENOSPC.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bg_release_drain_stall_ms ] || { skip "bg_release_drain_stall_ms is missing"; ct_exit; }
BG_POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"

IMG="$(ct_image 1200 reldrain)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt reldrain)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
NBG="$("$MAP" "$DEV" | grep -c '^bg ' || true)"
[ "$NBG" = 2 ] || { fail "setup: want 2 Block Groups, got $NBG"; ct_exit; }
"$BG_POKE" "$DEV" 0 0 sync-zg >/dev/null # the aggregate moves with the count
"$BG_POKE" "$DEV" 0 0 fill-bitmap >/dev/null
ct_param_set scrub 0
ct_param_set hb_interval_secs 2
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
MARK="$(dmesg_mark)"
ct_param_set bg_release_drain_stall_ms 4000
HELD=""
for _ in $(seq 1 20); do
    dmesg_since "$MARK" | grep -q "BG 1 release: drained, pausing" && { HELD=1; break; }
    sleep 0.5
done
[ -n "$HELD" ] || { fail "setup: no release drained Block Group 1"; ct_param_set bg_release_drain_stall_ms 0; ct_umount "$MNT"; ct_exit; }
RC=0
dd if=/dev/zero of="$MNT/w" bs=64k count=16 conv=fsync status=none 2>/dev/null || RC=$?
ct_param_set bg_release_drain_stall_ms 0
[ "$RC" = 0 ] && pass "a write inside the release's drain completed" ||
    fail "a write inside the release's drain failed ($RC) on a volume with a whole free Block Group"
dmesg_since "$MARK" | grep -q "pick_bg failed" &&
    fail "the allocator reported no space during the drain: $(dmesg_since "$MARK" | grep -m1 'pick_bg failed')" ||
    pass "the allocator never reported no space"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -E '^ERR' <<<"$OUT" | grep -qE 'aggregate|pool|referenced' &&
    fail "fsck: $(grep -E '^ERR' <<<"$OUT" | grep -E 'aggregate|pool|referenced' | head -2)" ||
    pass "fsck: counts and references consistent (the filled group's bits are a staged leak)"
ct_exit
