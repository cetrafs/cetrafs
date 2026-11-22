#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a pending free consumed before its Zone Group left this node is not applied after
# ct-timeout: 240
#
# A drain consumes a batch of queue entries, then applies each one,
# taking alloc_mutex per entry. Under the mutex the apply judged only the
# group's free_gen, and before it the owner read from the descriptor:
# a Zone Group released whole keeps both (its groups stay its members,
# and a claim of the Zone Group moves no group's generation). So an entry
# applied after the release cleared bits in a bitmap that was no longer
# this node's -- with a peer's claim and allocation in between, a live
# block of the peer's read FREE (audit 2026-11-22, N-60). The direct free
# already asks under the mutex whether the group is still ours; the apply
# now asks the same.
#
# Staged on one node, two Zone Groups: ZG 0 full, ZG 1 claimed on demand
# and emptied again. Two entries for already-free blocks of ZG 1 are
# planted in its queue (a duplicate copy is exactly that). A writer's
# drain applies the first and pf_apply_stall_ms holds it before the
# second; meanwhile the heartbeat gives ZG 1 back. When the drain
# resumes, the second entry must be dropped as left -- not reach the
# bitmap (pf_apply_bmap_lookups).
#
# DISCRIMINATION: the control, in-suite -- pf_apply_owner_unchecked=1,
# the old apply: the second entry goes on to the bitmap of the group
# that left.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in pf_apply_stall_ms pf_apply_owner_unchecked zg_release_hold bg_release_off; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
BG_POKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt pfafg)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set zg_release_hold 1
ct_param_set bg_release_off 1
ct_param_set pf_apply_owner_unchecked 0
ct_param_set pf_apply_stall_ms 0
ct_param_set pf_drain_min_ms 600000

# run <tag> <unchecked> -> "left_drops lookups_after_release"
run() {
    local img dev proc L i out r0 l0 lk wpid rel=0
    img="$(ct_image 1200 "pfafg$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_umount "$MNT"
    for bg in $(ct_bgs_of_zg "$dev" 0); do "$BG_POKE" "$dev" "$bg" 0 fill-bitmap >/dev/null; done
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    zg_owner() { grep -oP "^\s+zg $1: owner=\K\S+" "$proc/info"; }
    info() { sed -n "s/^$1: //p" "$proc/info"; }
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 conv=fsync status=none
    sync
    L="$("$PP" "$img" extent "$(stat -c %i "$MNT/f")" | awk '{ print $1; exit }')"
    rm -f "$MNT/f"
    sync
    [ "$(zg_owner 1)" = 0 ] && [ -n "$L" ] ||
        { fail "$1 setup: ZG 1 is owned by $(zg_owner 1), first block '$L'"; ct_umount "$MNT"; return; }
    "$PP" "$img" add 1 "$L" 1 >/dev/null
    "$PP" "$img" add 1 $((L + 1)) 1 >/dev/null
    [ "$("$PP" "$img" dump 1 | wc -l)" = 2 ] || { fail "$1 setup: the two entries are not queued"; ct_umount "$MNT"; return; }
    echo "$2" >"$P/pf_apply_owner_unchecked"
    echo "hb_interval_secs=5" >"$proc/controls"
    r0="$(info pf_apply_left_drops)"
    ct_param_set pf_drain_min_ms 0
    ct_param_set pf_apply_stall_ms 20000 # one-shot: after the first apply
    dd if=/dev/urandom of="$MNT/w" bs=4096 count=1 conv=fsync status=none &
    wpid=$!
    sleep 1
    ct_param_set pf_drain_min_ms 600000
    ct_param_set zg_release_hold 0
    for _ in $(seq 1 30); do
        [ "$(zg_owner 1)" = none ] && { rel=1; break; }
        sleep 0.5
    done
    ct_param_set zg_release_hold 1
    l0="$(info pf_apply_bmap_lookups)"
    kill -0 "$wpid" 2>/dev/null && i=held || i=done
    ct_param_set pf_apply_stall_ms 0
    wait "$wpid" || true
    lk=$(($(info pf_apply_bmap_lookups) - l0))
    echo 0 >"$P/pf_apply_owner_unchecked"
    out="$1 released=$rel writer=$i left_drops=$(($(info pf_apply_left_drops) - r0)) lookups=$lk"
    log "$out"
    [ "$rel" = 1 ] && [ "$i" = held ] || { fail "$1 setup: ZG 1 released=$rel while the drain was $i"; ct_umount "$MNT"; return; }
    RES="$out"
    ct_umount "$MNT"
    ct_fsck "$dev" >/dev/null && pass "$1: fsck clean" || fail "$1: fsck reports damage"
}

get() { echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

RES=""
run ctl 1
[ -n "$RES" ] && [ "$(get lookups "$RES")" -ge 1 ] && [ "$(get left_drops "$RES")" = 0 ] &&
    pass "control: unchecked, the entry went on to the bitmap of the group that left ($RES)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $RES"
RES=""
run fixed 0
[ -n "$RES" ] && [ "$(get left_drops "$RES")" = 1 ] && [ "$(get lookups "$RES")" = 0 ] &&
    pass "the entry applied after ZG 1 left was dropped, its bitmap untouched ($RES)" ||
    fail "the entry applied after ZG 1 left: $RES"
ct_exit
