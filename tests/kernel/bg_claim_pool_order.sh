#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a crash inside a Block Group claim never leaves the pool overstating
#
# Unowned Block Groups' capacity is counted in a pool shard on the Zone
# Group record; statfs adds it. A release credits the shard BEFORE its
# descriptor reads FREE, so a crash between the two understates. A claim
# did the opposite: it swapped the descriptor to its owner first and
# debited the shard after, so a crash between the two left the group
# owned AND still counted in the pool -- df overstated by a whole Block
# Group until fsck -r (N-15). The claim now debits first and credits back
# only when its swap is refused.
#
# Staged on one node: two Block Groups; the second is released to the
# pool, then a writer has to claim it back. The claim is held between
# its two counter moves (bg_claim_pool_stall_ms), and the backing image
# is copied there -- what a crash at that instant leaves -- and checked
# by fsck: the pool shard must not exceed what is really free in the
# unowned groups. The claim then completes; fsck clean.
#
# DISCRIMINATION: bg_claim_debit_late=1 restores the old order: the copy
# shows the pool shard above the truth by the group's size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bg_claim_pool_stall_ms bg_claim_debit_late bg_release_off; do
    [ -w /sys/module/cetrafs/parameters/$p ] || { skip "$p is missing"; ct_exit; }
done
MAP="$(ct_helper bg_map)"
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt bgcpo)"
compress_timing
ct_track mnt "$MNT"
for k in bg_release_off bg_claim_debit_late bg_claim_pool_stall_ms; do
    ct_param_set "$k" "$(cat /sys/module/cetrafs/parameters/$k)"
done
ct_param_set scrub 0
ct_param_set auto_defrag 0

# round <tag> <late 0|1> -> RES "<pool on the copy> <truth on the copy> <fsck ERR after>"
round() {
    local img dev snap sdev mark i=0 line pool truth err w
    img="$(ct_image 1200 "bgcpo$1")"
    dev="$(ct_loop "$img")"
    snap="$img.snap"; ct_track file "$snap"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | sed -n 's/^counts [0-9]* //p')" = 2 ] || { RES="setup-2bg"; return; }
    ct_param_set bg_release_off 1
    ct_mount "$dev" "$MNT"
    # Fill until a file reaches the second Block Group, then drop it: the
    # first nearly full, the second empty -- and released to the pool.
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
    ct_param_set bg_claim_debit_late "$2"
    ct_param_set bg_claim_pool_stall_ms 8000
    mark="$(dmesg_mark)"
    ( dd if=/dev/zero of="$MNT/w" bs=1M count=64 conv=fsync status=none 2>/dev/null || true ) &
    w=$!
    wait_for 20 'dmesg_since "'"$mark"'" | grep -q "BG 1 claim: between its counter moves"' ||
        { ct_param_set bg_claim_pool_stall_ms 0; wait "$w" || true; RES="setup-noclaim"; ct_umount "$MNT"; return; }
    cp --sparse=always "$img" "$snap"
    # On the copy this node crashed: recorded DEAD, as the peer that
    # watched it stop would, so fsck does not watch the row itself.
    "$NPOKE" "$snap" "$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")" --depart 2 >/dev/null
    wait "$w" || true
    ct_param_set bg_claim_pool_stall_ms 0
    ct_param_set bg_claim_debit_late 0
    ct_umount "$MNT"
    sdev="$(ct_loop "$snap")"
    line="$(ct_fsck "$sdev" 2>&1 | grep -m1 'pool_free_blocks' || true)"
    losetup -d "$sdev" 2>/dev/null || true
    pool="$(sed -n 's/.*pool_free_blocks \([0-9]*\) != \([0-9]*\).*/\1/p' <<<"$line")"
    truth="$(sed -n 's/.*pool_free_blocks \([0-9]*\) != \([0-9]*\).*/\2/p' <<<"$line")"
    err="$(ct_fsck "$dev" 2>&1 | grep -c '^ERR' || true)"
    RES="${pool:-same} ${truth:-same} $err"
}

round c 1
read -r CP CT CE <<<"$RES"
log "control (debit after the swap): the copy's pool shard ${CP} against ${CT} really free"
round f 0
read -r P T E <<<"$RES"
log "fixed: the copy's pool shard ${P} against ${T} really free; fsck ERR after the claim: $E"
case "$P" in setup-*) fail "setup: $P"; ct_exit ;; esac
case "$CP" in setup-*) fail "control setup: $CP"; ct_exit ;; esac
{ [ "$P" = same ] || [ "$P" -le "$T" ]; } &&
    pass "1: a crash inside the claim leaves the pool shard at or below the truth" ||
    fail "1: the copy's pool shard $P exceeds the $T really free -- df would overstate"
[ "$E" = 0 ] && pass "2: the completed claim leaves fsck clean" || fail "2: fsck reports $E error(s)"
[ "$CP" != same ] && [ "$CP" -gt "$CT" ] && pass "control: the old order overstates on the copy ($CP > $CT)" ||
    fail "control: the copy reads $CP against $CT -- the staging proves nothing"
ct_exit
