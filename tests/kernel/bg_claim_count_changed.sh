#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Block Group claim swaps only the count it debited the pool by
#
# A claim debits the Zone Group's pool shard by the free count it read,
# then swaps the descriptor to its owner (N-15). The swap checked only
# that the group was still FREE, not that its count was still the one
# debited: a peer that claimed the group, allocated from it and released
# it in between left another count, and the claim took the group anyway
# -- the shard off by the difference until fsck (audit 2026-11-22 N-279).
# The swap now refuses an image whose count is not the debited one; the
# debit is given back and the scan goes on.
#
# Staged on one node: four Block Groups, three released to the pool; a
# writer claims one back and is held between the debit and the swap
# (bg_claim_pool_stall_ms). There, a peer's whole cycle is played on the
# device: the group filled (count 0, bitmap full) and the shard moved by
# what that peer's claim and release would have moved it (-count).
#   1. after the writer completes and the volume is unmounted, fsck
#      finds the pool shard equal to the truth, and nothing else wrong.
#
# DISCRIMINATION: bg_claim_count_unchecked=1 (as before): the claim
# takes the filled group, and fsck reports the shard off by its count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bg_claim_pool_stall_ms bg_claim_count_unchecked bg_release_off; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
MAP="$(ct_helper bg_map)"
BGP="$(ct_helper bg_poke)"
ZGP="$(ct_helper zg_poke)"
MNT="$(ct_mnt bgccc)"
compress_timing
ct_track mnt "$MNT"
for k in bg_release_off bg_claim_count_unchecked bg_claim_pool_stall_ms; do
    ct_param_set "$k" "$(cat /sys/module/cetrafs/parameters/$k)"
done
ct_param_set scrub 0
ct_param_set auto_defrag 0

# round <tag> <unchecked 0|1> -> RES "claimed=<bg> count=<X> poolline=<0|1> err=<n>"
round() {
    local img dev mark i=0 w k x p line err
    img="$(ct_image 2200 "bgccc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | sed -n 's/^counts [0-9]* //p')" -ge 4 ] || { RES="setup-4bg"; return; }
    ct_param_set bg_release_off 1
    ct_mount "$dev" "$MNT"
    # Fill until a file reaches the second Block Group, then drop it: the
    # first nearly full, the rest empty -- and released to the pool.
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
    sleep 3
    ct_param_set bg_release_off 1
    ct_param_set bg_claim_count_unchecked "$2"
    ct_param_set bg_claim_pool_stall_ms 6000
    mark="$(dmesg_mark)"
    ( dd if=/dev/zero of="$MNT/w" bs=1M count=64 conv=fsync status=none 2>/dev/null || true ) &
    w=$!
    wait_for 20 'dmesg_since "'"$mark"'" | grep -q "claim: between its counter moves"' ||
        { ct_param_set bg_claim_pool_stall_ms 0; wait "$w" || true; RES="setup-noclaim"; ct_umount "$MNT"; return; }
    k="$(dmesg_since "$mark" | grep -oP 'BG \K[0-9]+(?= claim: between its counter moves)' | head -1)"
    x="$("$BGP" "$dev" "$k" --dump | grep -oP 'free_data_blocks=\K[0-9]+')"
    p="$("$ZGP" "$dev" 0 stamp | grep -oP 'pool_free_blocks=\K[0-9]+')"
    # A peer's cycle, all of it inside the window: it claimed the group
    # (shard -x), filled it, and released it full (shard +0).
    "$BGP" "$dev" "$k" 0 fill-bitmap >/dev/null
    "$ZGP" "$dev" 0 pool $((p - x)) >/dev/null
    ct_param_set bg_claim_pool_stall_ms 0
    wait "$w" || true
    ct_param_set bg_claim_count_unchecked 0
    ct_umount "$MNT"
    line="$(ct_fsck "$dev" 2>&1 | grep -c 'pool_free_blocks' || true)"
    err="$(ct_fsck "$dev" 2>&1 | grep -c '^ERR' || true)"
    RES="claimed=$k count=$x pool=$p poolline=$line err=$err"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (count unchecked): $C"
case "$R$C" in *setup-*) fail "setup: $R | $C"; ct_exit ;; esac
[ "$(get count "$R")" -gt 0 ] && [ "$(get pool "$R")" -ge "$(get count "$R")" ] ||
    { fail "setup: the claimed group had no count, or the shard was below it: $R"; ct_exit; }
[ "$(get poolline "$R")" = 0 ] && [ "$(get err "$R")" = 0 ] &&
    pass "1: the claim refused the changed group; the pool shard matches the truth, fsck clean" || fail "1: $R"
[ "$(get poolline "$C")" -ge 1 ] &&
    pass "control: with the count unchecked the claim took the changed group, and the shard is off" ||
    fail "control: $C -- the staging does not reach the swap"
ct_exit
