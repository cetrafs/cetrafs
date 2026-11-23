#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one Block Group the Zone Group recount cannot read does not leave the rest unseeded
#
# Taking a Zone Group recounts every member Block Group from its bitmap,
# then corrects the group's aggregate from the sum. On the first member
# that could not be recounted it returned: the members after it were not
# recounted at all, the aggregate was never corrected, and the delta it
# had already taken for that aggregate was lost -- the Zone Group's free
# count stayed wrong until an ENOSPC recount (N-8). The recount now goes
# on past a failed member, counts that member by its own descriptor, and
# corrects the aggregate; only when a member has no count at all does it
# leave the aggregate alone and give the delta back.
#
# (The audit also expected the later members' deltas to be refused for
# want of a seeded epoch; that did not show here, clean or unclean, and
# check 1 stays as the guard for it.)
#
# One Zone Group of at least three Block Groups, BG 0 and BG 1 poked
# full (their counts and bitmaps; the aggregate still says empty), this
# node's last mount ended in a crash so the re-attach recounts; that
# recount of BG 1 fails once (reconcile_fail_bg); then a write:
#   1. no delta of this node's is dropped;
#   2. after unmount, fsck finds the aggregate and every count right.
#
# DISCRIMINATION: reconcile_stop_on_fail=1 returns at the failed member,
# as before: fsck reports the Zone Group's aggregate wrong (check 2).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in reconcile_fail_bg reconcile_stop_on_fail; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt zgrmf)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set reconcile_fail_bg 0
ct_param_set reconcile_stop_on_fail 0
compress_timing
P=/sys/module/cetrafs/parameters

# <tag> <stop_on_fail 0|1> -> RES "<recount failed> <dropped> <fsck drift lines>"
round() {
    local dev mark failed dropped drift me
    dev="$(ct_dev 2200 "zgrmf$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$(ct_bgs_of_zg "$dev" 0 | wc -l)" -ge 3 ] || { RES="nobg 0 0"; return; }
    ct_mount "$dev" "$MNT"
    me="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    # It crashed instead: the re-attach is unclean, and every member's
    # count epoch moves with the recount.
    "$NPOKE" "$dev" "$me" --depart 0 >/dev/null
    "$BG_POKE" "$dev" 0 0 fill-bitmap >/dev/null
    "$BG_POKE" "$dev" 1 0 fill-bitmap >/dev/null
    blockdev --flushbufs "$dev"
    echo "$2" >$P/reconcile_stop_on_fail
    echo 2 >$P/reconcile_fail_bg # BG 1
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    echo 0 >$P/reconcile_fail_bg
    echo 0 >$P/reconcile_stop_on_fail
    dd if=/dev/urandom of="$MNT/f" bs=1M count=8 conv=fsync status=none
    sync
    ct_umount "$MNT"
    failed="$(dmesg_since "$mark" | grep -c 'reconcile: BG 1 could not be reconciled' || true)"
    dropped="$(dmesg_since "$mark" | grep -c 'free delta .* dropped' || true)"
    drift="$(ct_fsck "$dev" 2>&1 | grep -ciE 'free.*count|free_data_blocks|drift' || true)"
    RES="$failed $dropped $drift"
}

round c 1
read -r CF CD CR <<<"$RES"
log "control (stops at the failed member): recount failures $CF, deltas dropped $CD, fsck count lines $CR"
round f 0
read -r F D R <<<"$RES"
log "fixed: recount failures $F, deltas dropped $D, fsck count lines $R"
[ "$F" != nobg ] && [ "$F" -ge 1 ] && pass "setup: the mount's recount of BG 1 failed" || fail "setup: $RES"
[ "$D" = 0 ] && pass "1: no delta of this node's was dropped" || fail "1: $D delta(s) dropped"
[ "$R" = 0 ] && pass "2: fsck finds no free-count drift" || fail "2: fsck reports $R free-count line(s)"
[ "$CF" -ge 1 ] && [ "$CR" -ge 1 ] && pass "control: stopping at the failed member leaves the aggregate wrong" ||
    fail "control: recount failures $CF, fsck count lines $CR -- the suite cannot tell"
ct_exit
