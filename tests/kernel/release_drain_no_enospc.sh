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
#
# Part 2: that wait is KILLABLE (class 20). A release can hold it across
# a Block Group's discard, and a plain down_read() kept a SIGKILLed
# writer for the whole hold. Staged the same way with a longer hold (the
# drained Block Group is the only space, so the writer waits for the
# release); the writer is killed once its stack shows the wait, and
# must be gone well before the hold ends. Control:
# release_wait_unkillable=1, the old wait, outlives the kill.
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

# --------------------------------------------------------- 2: killable
[ -w /sys/module/cetrafs/parameters/release_wait_unkillable ] || { skip "release_wait_unkillable is missing"; ct_exit; }
ct_param_set release_wait_unkillable 0
# <tag>: sets WAITED (the writer reached the release wait) and GONE_MS
# (how long after SIGKILL it was gone)
killed_wait() {
    local w t0 i
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    "$BG_POKE" "$DEV" 0 0 sync-zg >/dev/null
    "$BG_POKE" "$DEV" 0 0 fill-bitmap >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    MARK="$(dmesg_mark)"
    ct_param_set bg_release_drain_stall_ms 15000
    HELD=""
    for _ in $(seq 1 20); do
        dmesg_since "$MARK" | grep -q "BG 1 release: drained, pausing" && { HELD=1; break; }
        sleep 0.5
    done
    [ -n "$HELD" ] || { fail "$1: setup: no release drained Block Group 1"; ct_param_set bg_release_drain_stall_ms 0; ct_exit; }
    dd if=/dev/zero of="$MNT/k" bs=64k count=16 conv=fsync status=none 2>/dev/null &
    w=$!
    WAITED=""
    for _ in $(seq 1 40); do
        grep -qE 'cetrafs_sb_release_(wait|read_lock)' "/proc/$w/stack" 2>/dev/null && { WAITED=1; break; }
        sleep 0.1
    done
    t0=$(date +%s%N)
    kill -9 "$w" 2>/dev/null || true
    for i in $(seq 1 200); do kill -0 "$w" 2>/dev/null || break; sleep 0.1; done
    GONE_MS=$((($(date +%s%N) - t0) / 1000000))
    wait "$w" 2>/dev/null || true
    ct_param_set bg_release_drain_stall_ms 0
    ct_umount "$MNT"
    log "$1: the writer reached the release wait: ${WAITED:-no}; gone ${GONE_MS} ms after SIGKILL"
}
ct_param_set release_wait_unkillable 1
killed_wait control
ct_param_set release_wait_unkillable 0
[ -n "$WAITED" ] || { fail "control: setup: the writer never waited for the release"; ct_exit; }
[ "$GONE_MS" -ge 5000 ] && pass "control: the old wait kept the killed writer ${GONE_MS} ms" ||
    fail "control: the killed writer was gone in ${GONE_MS} ms -- the suite cannot tell the two apart"
killed_wait fix
[ -n "$WAITED" ] || { fail "2: setup: the writer never waited for the release"; ct_exit; }
[ "$GONE_MS" -lt 3000 ] && pass "2: a killed writer waiting for a release was gone in ${GONE_MS} ms" ||
    fail "2: a killed writer waiting for a release took ${GONE_MS} ms to go"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -E '^ERR' <<<"$OUT" | grep -qE 'aggregate|pool|referenced' &&
    fail "fsck: $(grep -E '^ERR' <<<"$OUT" | grep -E 'aggregate|pool|referenced' | head -2)" ||
    pass "fsck: counts and references consistent (the filled group's bits are a staged leak)"
ct_exit
