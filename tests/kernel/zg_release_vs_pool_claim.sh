#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a pool Block Group is never claimed into a Zone Group being released
#
# A writer that has used up its owned Block Groups claims one from the
# pool into "the first Zone Group this node owns". A Zone Group being
# handed back is still in owned_zgs until its release CAS lands, so it
# could be that first one: the claimed group became allocatable at once,
# took the writer's blocks with its bits only in this node's memory, and
# left with the Zone Group for the next owner to allocate again (audit
# 2026-11-14 A-2). The claim now waits out any release
# (release_rwsem, read).
#
# Staged on one node, three Zone Groups, four Block Groups: 0..2 in Zone
# Groups 0..2, 3 put in the pool. Zone Group 0 holds the root directory,
# so it is filled and left unowned. The mount owns Zone Group 2 (its
# aggregate made to look fuller); a fallocate fills it exactly, a second
# one spills into Zone Group 1, which the allocator claims, and is
# deleted. Zone Group 1 is then owned, empty and the first owned; Zone
# Group 2 is full. The surplus release takes Zone Group 1 and
# zg_release_stall_ms holds it just before its CAS; a write starts
# inside the hold and has to claim Block Group 3 (TEST ONLY
# alloc_claim_zg_off: not the full, unowned Zone Group 0 instead).
#   setup: the hold was reached, and Zone Group 1 was released;
#   1. the write succeeded;
#   2. Block Group 3 belongs to a Zone Group this node still owns (on
#      the device, after unmount).
#
# DISCRIMINATION: release_claim_unlocked=1 (the old claim): 2 fails --
# Block Group 3 left with Zone Group 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in zg_release_stall_ms release_claim_unlocked zg_release_hold bg_release_off alloc_claim_zg_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
ZG_POKE="$(ct_helper zg_poke)"
MNT="$(ct_mnt zrpc)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set zg_release_hold 1
ct_param_set bg_release_off 1 # the Zone Group's own hand-back is the path staged
ct_param_set release_claim_unlocked 0
ct_param_set zg_release_stall_ms 0
ct_param_set alloc_claim_zg_off 0

# <unlocked 0|1> -> "staged=<yes|no> held=<0|1> released=<0|1> write=<rc> bg3zg=<n> bg3owner=<node> me=<node>"
round() {
    local dev proc me mark held=0 rel=0 rc=0 z o free2
    dev="$(ct_loop "$(ct_image 2400 "zrpc$1")")"
    ct_mkfs "$dev" -z 3 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | grep -c '^bg ')" = 4 ] || { echo "staged=no nbg=$("$MAP" "$dev" | grep -c '^bg ')"; return; }
    "$BG_POKE" "$dev" 3 --owner 65535 >/dev/null
    "$BG_POKE" "$dev" 0 0 sync-zg >/dev/null
    "$BG_POKE" "$dev" 0 0 fill-bitmap >/dev/null
    "$ZG_POKE" "$dev" 2 free 100000 >/dev/null # the mount claims the fuller one: Zone Group 2
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    me="$(sed -n 's/^this_node_id: //p' "$proc/info")"
    # fill Zone Group 2 exactly; a spill makes the allocator claim Zone
    # Group 1; deleting the spill leaves it owned and empty
    free2="$(grep -P '^\s+zg 2: ' "$proc/info" | grep -oP 'free_data_blocks=\K[0-9]+' || echo 0)"
    [ "$free2" -gt 0 ] && fallocate -l "$((free2 * 4096))" "$MNT/fill"
    fallocate -l 16M "$MNT/spill"
    sync
    rm -f "$MNT/spill"
    sync
    grep -P '^\s+zg [0-9]+:' "$proc/info" | sed 's/^/  /' >&2
    if ! grep -qP "^\s+zg 1: owner=$me " "$proc/info" || ! grep -qP "^\s+zg 2: owner=$me " "$proc/info" ||
        grep -qP "^\s+zg 0: owner=$me " "$proc/info"; then
        echo "staged=no"
        ct_umount "$MNT"
        return
    fi
    echo "$1" >/sys/module/cetrafs/parameters/release_claim_unlocked
    # From here the writer must reach the pool: the full, unowned Zone
    # Group 0 is not claimed first (TEST ONLY alloc_claim_zg_off).
    echo 1 >/sys/module/cetrafs/parameters/alloc_claim_zg_off
    mark="$(dmesg_mark)"
    echo 6000 >/sys/module/cetrafs/parameters/zg_release_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/zg_release_hold
    echo "hb_interval_secs=5" >"$proc/controls"
    for _ in $(seq 1 40); do
        dmesg_since "$mark" | grep -q "ZG 1 release: members ready, pausing" && { held=1; break; }
        sleep 0.5
    done
    if [ "$held" = 1 ]; then
        dd if=/dev/urandom of="$MNT/w" bs=1M count=64 conv=fsync status=none 2>/dev/null || rc=$?
    fi
    for _ in $(seq 1 40); do
        grep -qP "^\s+zg 1: owner=none" "$proc/info" && { rel=1; break; }
        sleep 0.5
    done
    echo 1 >/sys/module/cetrafs/parameters/zg_release_hold
    echo 0 >/sys/module/cetrafs/parameters/zg_release_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/release_claim_unlocked
    echo 0 >/sys/module/cetrafs/parameters/alloc_claim_zg_off
    dmesg_since "$mark" | grep -E "claimed free BG|gave back ZG|claimed one more" | sed 's/^/  /' >&2
    ct_umount "$MNT"
    z="$("$MAP" "$dev" | awk '$1 == "bg" && $2 == 3 { split($3, a, "="); print a[2] }')"
    o="$("$MAP" "$dev" | awk -v Z="$z" '$1 == "zg" && $2 == Z { split($3, a, "="); print a[2] }')"
    echo "staged=yes held=$held released=$rel write=$rc bg3zg=$z bg3owner=${o:-none} me=$me"
}

get() { sed -n "s/.*$1=\([0-9a-z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "locked claim: $R"
C="$(round 1)"
log "control (unlocked claim): $C"
for v in "$R" "$C"; do
    [ "$(get staged "$v")" = yes ] && [ "$(get held "$v")" = 1 ] && [ "$(get released "$v")" = 1 ] ||
        { fail "setup: not staged, held and released ($v)"; ct_exit; }
done
pass "setup: Zone Group 1's release was held before its CAS, and then landed"
[ "$(get write "$R")" = 0 ] && pass "1: the write inside the hold succeeded" || fail "1: the write failed ($(get write "$R"))"
[ "$(get bg3owner "$R")" = "$(get me "$R")" ] &&
    pass "2: Block Group 3 belongs to Zone Group $(get bg3zg "$R"), owned by this node" ||
    fail "2: Block Group 3 belongs to Zone Group $(get bg3zg "$R"), owner $(get bg3owner "$R") -- it left with the release"
[ "$(get bg3owner "$C")" != "$(get me "$C")" ] &&
    pass "control: the unlocked claim put Block Group 3 in the released Zone Group $(get bg3zg "$C")" ||
    fail "control: the unlocked claim kept Block Group 3 owned -- the suite does not reach the window"
ct_exit
