#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group steal fences and replays its dead owner outside the claim mutex
#
# Taking a dead owner's Zone Group fences the owner and replays its whole
# journal, with the claim wait -- and did both under the claim mutex,
# which every writer of this node that needs a Zone Group takes, plainly:
# a heartbeat steal stalled them all, uninterruptibly, for as long as the
# replay ran (audit 2026-11-15 BM-39). The fence and replay now run before
# the mutex is taken (a pick that lands on a dead owner's group drops it
# for them), the claim under it finds the journal replayed, and an
# allocator takes the mutex killably.
#
# Zone Group 0 belongs to a dead row 1; the mount steals it. A test stall
# right after the steal's fence says whether the claim mutex is held:
#   fixed:   not held, and the steal completes;
#   control: zg_settle_locked=1 -- held, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
IMG="$(ct_image 560 zgset)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgset)"
ct_track mnt "$MNT"
ct_param_set zg_settle_locked 0
ct_param_set zg_settle_stall_ms 0

# <tag> <locked 0|1> -> RES
round() {
    local mark log
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    echo x >"$MNT/f"
    ct_umount "$MNT"
    poke_dead_peer "$DEV" 1 aa
    "$ZG_POKE" "$DEV" 0 1 >/dev/null
    echo "$2" >/sys/module/cetrafs/parameters/zg_settle_locked
    echo 1000 >/sys/module/cetrafs/parameters/zg_settle_stall_ms
    mark="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT"
    wait_for 60 "dmesg_since '$mark' | grep -q 'reclaiming ZG 0 from stale node 1'" || true
    log="$(dmesg_since "$mark")"
    RES="held=$(sed -n 's/.*settle stall, claim mutex held=\([01]\).*/\1/p' <<<"$log" | head -1)"
    grep -q 'reclaiming ZG 0 from stale node 1' <<<"$log" && RES="$RES stolen=yes" || RES="$RES stolen=no"
    echo x >"$MNT/g" && RES="$RES write=ok" || RES="$RES write=fail"
    echo 0 >/sys/module/cetrafs/parameters/zg_settle_locked
    echo 0 >/sys/module/cetrafs/parameters/zg_settle_stall_ms
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (settled under the mutex): $C"
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
[ "$(field held "$F")" = 0 ] && pass "fixed: the claim mutex was free across the dead owner's fence and replay" ||
    fail "fixed: $F"
[ "$(field stolen "$F")" = yes ] && [ "$(field write "$F")" = ok ] && [ "$(field fsck "$F")" = ok ] &&
    pass "fixed: the steal completed, the volume writes and checks clean" || fail "fixed: $F"
[ "$(field held "$C")" = 1 ] &&
    pass "control: as before, the claim mutex was held across them" ||
    fail "control: the stall did not see the mutex held -- the suite does not reach it: $C"
ct_exit
