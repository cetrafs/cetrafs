#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group claim recounts outside the claim mutex, and replays its dead owner once
#
# After a claim's swap, the layout catch-up, the members' cache drops and
# the free-count recount -- a read of every member's bitmap -- ran under
# the claim mutex, which every writer of this node needing a Zone Group,
# the heartbeat's claims and a DIO completion's conversion in a kworker
# take (audit 2026-11-15 BM-39, BM-40). They now run with the mutex
# dropped; the group is marked claiming meanwhile, so nothing caches it
# mid-recount. And a steal whose dead owner was just replayed outside the
# mutex no longer replays it again under it (F-43).
#
# Staged as zg_claim_settle_unlocked.sh: Zone Group 0 belongs to a dead
# row 1 and the mount steals it. Its recount is held 1 s
# (zg_reconcile_stall_ms), which says whether the claim mutex is held:
#   fixed:   not held, the dead owner's journal passed once (a skip
#            counted), the steal completes, writes and fsck clean;
#   control: zg_recount_locked=1 -- held, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
IMG="$(ct_image 560 zgrec)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgrec)"
ct_track mnt "$MNT"
ct_param_set zg_recount_locked 0
ct_param_set zg_reconcile_stall_ms 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <tag> <locked 0|1> -> RES
round() {
    local mark log
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    echo x >"$MNT/f"
    ct_umount "$MNT"
    poke_dead_peer "$DEV" 1 aa
    "$ZG_POKE" "$DEV" 0 1 >/dev/null
    echo "$2" >/sys/module/cetrafs/parameters/zg_recount_locked
    echo 1000 >/sys/module/cetrafs/parameters/zg_reconcile_stall_ms
    mark="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT"
    wait_for 60 "dmesg_since '$mark' | grep -q 'reclaiming ZG 0 from stale node 1'" || true
    log="$(dmesg_since "$mark")"
    RES="held=$(sed -n 's/.*ZG 0 reconcile: delta dropped, pausing .*claim mutex held=\([01]\).*/\1/p' <<<"$log" | head -1)"
    grep -q 'reclaiming ZG 0 from stale node 1' <<<"$log" && RES="$RES stolen=yes" || RES="$RES stolen=no"
    RES="$RES skips=$(info zg_claim_replay_skips)"
    echo x >"$MNT/g" && sync && RES="$RES write=ok" || RES="$RES write=fail"
    echo 0 >/sys/module/cetrafs/parameters/zg_recount_locked
    echo 0 >/sys/module/cetrafs/parameters/zg_reconcile_stall_ms
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (recount under the mutex): $C"
[ "$(field held "$F")" = 0 ] && pass "fixed: the claim mutex was free across the recount" || fail "fixed: $F"
[ "$(field skips "$F")" -ge 1 ] && pass "fixed: the dead owner's journal was not replayed a second time ($F)" ||
    fail "fixed (F-43): $F"
[ "$(field stolen "$F")" = yes ] && [ "$(field write "$F")" = ok ] && [ "$(field fsck "$F")" = ok ] &&
    pass "fixed: the steal completed, the volume writes and checks clean" || fail "fixed: $F"
[ "$(field held "$C")" = 1 ] &&
    pass "control: as before, the claim mutex was held across the recount" ||
    fail "control: the stall did not see the mutex held -- the suite does not reach it: $C"
ct_exit
