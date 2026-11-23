#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two claims of one Block Group: a win on a refused pool debit owes the debit
#
# A claim debits the unowned pool's shard by the group's count, then swaps
# the descriptor to its owner (bg_claim_pool_order.sh). Two claims of the
# same group both read it FREE; the shard takes the first debit and
# refuses the second, which would take it below zero. The second claim
# went on and swapped -- and won, while the first, holding the debit,
# lost its swap and gave the debit back: the group owned AND its count
# in the pool, fsck "pool_free_blocks 130816 != 0", df over by a whole
# Block Group. Two writers running out of space together are enough
# (bg_claim_free.sh caught it under load). A claim that wins on a
# refused debit now OWES it, and lands it once the loser's give-back is
# in (cetrafs_pool_owed_settle()).
#
# Staged on one node: two Block Groups, the second released to the pool.
# Writer A runs out of space and claims it, and is held between its debit
# and its swap (bg_claim_pool_stall_ms). Writer B runs out of space
# meanwhile and reaches the same group:
#   setup: B's claim found the shard's debit refused, and B won the group;
#   1. B's owed debit landed after A's give-back;
#   2. fsck clean: the pool shard holds what is really unowned.
#
# DISCRIMINATION: bg_claim_debit_refused_ok=1 -- B wins and owes nothing:
# fsck reports the pool shard over by the group's size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bg_claim_pool_stall_ms bg_claim_debit_refused_ok bg_release_off; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt bgcrd)"
# No compress_timing: with it, B stayed blocked until A's claim had
# finished and never met the refused debit, so nothing was staged.
ct_track mnt "$MNT"
for k in bg_release_off bg_claim_debit_refused_ok bg_claim_pool_stall_ms; do
    ct_param_set "$k" "$(cat /sys/module/cetrafs/parameters/$k)"
done
ct_param_set scrub 0
ct_param_set auto_defrag 0

# round <tag> <refused_ok 0|1> -> RES "<B refused 0|1> <owner while A held> <pool ERR lines> <ERR lines> <owed landed>"
round() {
    local dev mark i=0 wa wb refused owner perr err out landed
    dev="$(ct_dev 1200 "bgcrd$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | sed -n 's/^counts [0-9]* //p')" = 2 ] || { RES="setup-2bg"; return; }
    ct_param_set bg_release_off 1
    ct_mount "$dev" "$MNT"
    # The first Block Group nearly full, the second empty and released.
    while :; do
        dd if=/dev/zero of="$MNT/f$i" bs=1M count=16 conv=fsync status=none 2>/dev/null || break
        sync
        "$MAP" "$dev" | awk '/^bg 1 /{split($5,a,"[=/]"); exit !(a[2] < a[3])}' && break
        i=$((i + 1))
        [ "$i" -gt 60 ] && break
    done
    rm -f "$MNT/f$i"
    sync
    mark="$(dmesg_mark)"
    ct_param_set bg_release_off 0
    wait_for 30 'dmesg_since "'"$mark"'" | grep -q "BG 1 handed back"' || { RES="setup-norelease"; ct_umount "$MNT"; return; }
    ct_param_set bg_release_off 1
    ct_param_set bg_claim_debit_refused_ok "$2"
    ct_param_set bg_claim_pool_stall_ms 10000
    mark="$(dmesg_mark)"
    ( dd if=/dev/zero of="$MNT/a" bs=1M count=64 conv=fsync status=none 2>/dev/null || true ) &
    wa=$!
    wait_for 20 'dmesg_since "'"$mark"'" | grep -q "BG 1 claim: between its counter moves"' ||
        { ct_param_set bg_claim_pool_stall_ms 0; wait "$wa" || true; RES="setup-noclaim"; ct_umount "$MNT"; return; }
    # B, while A is held: it runs out of space and reaches the same group.
    ( dd if=/dev/zero of="$MNT/b" bs=1M count=64 conv=fsync status=none 2>/dev/null || true ) &
    wb=$!
    wait_for 8 'dmesg_since "'"$mark"'" | grep -q "BG 1: its pool shard refused the claim"' || true
    refused=0
    dmesg_since "$mark" | grep -q "BG 1: its pool shard refused the claim" && refused=1
    # Who owns the group while A is still held: B, if B swapped.
    owner="$("$MAP" "$dev" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
    wait "$wa" || true
    wait "$wb" || true
    ct_param_set bg_claim_pool_stall_ms 0
    ct_param_set bg_claim_debit_refused_ok 0
    ct_umount "$MNT"
    landed="$(dmesg_since "$mark" | grep -c "BG 1: the claim's owed pool debit of [0-9]* landed" || true)"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    perr="$(grep -c 'pool_free_blocks' <<<"$out" || true)"
    err="$(grep -c '^ERR' <<<"$out" || true)"
    RES="$refused $owner $perr $err $landed"
}

round f 0
read -r FR FO FP FE FL <<<"$RES"
log "fixed: B refused=$FR, owner while A was held=$FO, fsck pool lines=$FP, ERR=$FE, owed landed=$FL"
round c 1
read -r CR CO CP CE CL <<<"$RES"
log "control (B owes nothing): B refused=$CR, owner while A was held=$CO, fsck pool lines=$CP, ERR=$CE"
case "$FR" in setup-*) fail "setup: $FR"; ct_exit ;; esac
case "$CR" in setup-*) fail "control setup: $CR"; ct_exit ;; esac
[ "$FR" = 1 ] && [ "$CR" = 1 ] && [ "$FO" != 65535 ] && [ "$CO" != 65535 ] ||
    { fail "setup: B did not win the group on a refused debit (fixed $FR/$FO, control $CR/$CO) -- the race was not staged"; ct_exit; }
[ "$FL" -ge 1 ] && pass "1: B's owed debit landed once A had given its own back" ||
    fail "1: B's owed debit never landed"
[ "$FP" = 0 ] && [ "$FE" = 0 ] && pass "2: fsck clean -- the pool shard holds what is really unowned" ||
    fail "2: fsck reports $FE error(s), $FP on the pool shard"
[ "$CP" -ge 1 ] &&
    pass "control: B won owing nothing, and the shard overstates ($CP pool line(s))" ||
    fail "control: $CP pool line(s) -- the staging proves nothing"
ct_exit
