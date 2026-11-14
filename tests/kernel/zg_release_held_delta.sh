#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group is not released while a member's count write is still in flight
#
# A claim of an unowned Zone Group keeps every matching member count's
# epoch (P3): it trusts that its previous owner left no write of a count
# to land late. The release is what makes that true. Its own flush skips
# a member another flusher -- a sync -- has already taken into a flight,
# and a delta in flight reads as none, so a release that only asked "is a
# delta pending?" handed the group over while our count write was still
# on its way: a late write on a group whose new owner kept the epoch. The
# release now takes each member's flush right first, which waits that
# write out.
#
# Staged as zg_release_flush.sh stages it: Zone Group 0 full, a file
# allocated into Zone Group 1 and punched empty while held open, so the
# heartbeat's surplus pass finds Zone Group 1 empty with its count delta
# pending. A sync then takes that delta into a flight held open for 45 s
# (bg_flush_stall_ms), and the heartbeat passes run meanwhile.
#   1. 35 s into the flight Zone Group 1 is still ours;
#   2. after the flight it is released; fsck clean.
#
# DISCRIMINATION: release_delta_guard_off=1: the release goes ahead with
# the write still in flight.
# ct-timeout: 400
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_flush_stall_ms release_delta_guard_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt zgheld)"
ct_track mnt "$MNT"
ct_param_set bg_flush_stall_ms 0
ct_param_set release_delta_guard_off 0

# <guard_off 0|1> -> "<owner 35 s into the flight> <owner after it> <fsck>"
round() {
    local dev proc o1 o2 out sp
    dev="$(ct_loop "$(ct_image 1200 "zgheld$1")")"
    ct_mkfs "$dev" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    for bg in $(ct_bgs_of_zg "$dev" 0); do "$BG_POKE" "$dev" "$bg" 0 fill-bitmap >/dev/null; done
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    owner() { grep -oP "^\s+zg 1: owner=\K\S+" "$proc/info"; }
    dd if=/dev/zero of="$MNT/f" bs=4096 count=64 conv=fsync status=none
    sync
    [ "$(owner)" = 0 ] || { echo "noclaim none ERR"; ct_umount "$MNT"; return; }
    exec 9<>"$MNT/f"
    fallocate -p -o 0 -l $((64 * 4096)) "$MNT/f"
    echo "$1" >/sys/module/cetrafs/parameters/release_delta_guard_off
    echo 45000 >/sys/module/cetrafs/parameters/bg_flush_stall_ms
    echo "hb_interval_secs=5" >"$proc/controls" # from the next tick: up to 15 s away
    sync &
    sp=$!
    sleep 35
    o1="$(owner)"
    wait "$sp" || true
    echo 0 >/sys/module/cetrafs/parameters/release_delta_guard_off
    echo 0 >/sys/module/cetrafs/parameters/bg_flush_stall_ms
    o2="$o1"
    for _ in $(seq 1 30); do
        o2="$(owner)"
        [ "$o2" = none ] && break
        sleep 1
    done
    exec 9>&-
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    # Zone Group 0's bitmap was filled by hand to force the claim: those
    # blocks are leaked by construction, and only they may be.
    out="$(grep -v 'data block(s) marked in use but referenced by no inode (leaked)' <<<"$out" || true)"
    if grep -qE '^(ERR|WARN)' <<<"$out"; then
        log "fsck ($1): $(grep -E '^(ERR|WARN)' <<<"$out" | head -2 | tr '\n' ' ')" >&2
        out=ERR
    else
        out=clean
    fi
    echo "$o1 $o2 $out"
}

read -r O1 O2 F <<<"$(round 0)"
log "fixed: owner $O1 35 s into the flight, $O2 after it; fsck $F"
read -r C1 C2 CF <<<"$(round 1)"
log "control (guard off): owner $C1 35 s into the flight"
[ "$O1" != noclaim ] && [ "$C1" != noclaim ] ||
    { fail "setup: Zone Group 1 was never claimed for the allocation"; ct_exit; }
[ "$O1" = 0 ] && pass "1: Zone Group 1 is still ours while a member's count write is in flight" ||
    fail "1: owner $O1 35 s into the flight -- released under a write in flight"
[ "$O2" = none ] && pass "2: after the flight it is released" || fail "2: still owned by $O2 after the flight"
[ "$F" = clean ] && pass "2: fsck clean" || fail "2: fsck not clean"
[ "$C1" = none ] && pass "control: with the guard off it was released with the write in flight" ||
    fail "control: owner $C1 with the guard off -- the heartbeat never tried a release during the flight"
ct_exit
