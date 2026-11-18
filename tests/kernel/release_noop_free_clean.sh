#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free that changes nothing leaves no dirty bitmap behind a hand-back
#
# A Block Group's hand-back syncs its bitmap, swaps its descriptor to
# FREE and drops the cached bitmap. A free between the sync and the swap
# that finds its bit already clear -- a duplicate, a re-applied
# pending-free copy, both of which the code expects -- changed nothing
# and still marked the bitmap block dirty, and the drop refuses a dirty
# buffer. Writeback then laid that all-clear image over the bitmap of
# the node that claimed the group next (audit 2026-11-14 A-3). Now a
# free dirties only a block it changed, and the hand-back forgets the
# group's bitmap blocks dirty or not.
#
# Staged on one node: Block Group 0 full, Block Group 1 owned and empty,
# released by the heartbeat. TEST ONLY release_noop_free frees an
# already-free block of it after its bitmap sync, before its CAS. Then,
# as the next owner would, bits are set in its bitmap on the device, and
# this node's cache is flushed (blockdev --flushbufs).
#   setup: the group was released, with the no-op free inside;
#   1. the next owner's bits survive this node's writeback.
#
# DISCRIMINATION: noop_free_dirties=1 (the old free and the old drop):
# 1 fails -- the all-clear image is written over them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in release_noop_free noop_free_dirties; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt rnfc)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set noop_free_dirties 0
ct_param_set release_noop_free 0
ct_param_set hb_interval_secs 30

# <old 0|1> -> "released=<0|1> noop=<0|1> peer=<bytes of the peer's bits after the flush>"
round() {
    local img dev mark rel=0 noop=0 g st off lba got
    img="$(ct_image 1200 "rnfc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | grep -c '^bg ')" = 2 ] || { echo "nbg"; return; }
    "$BG_POKE" "$dev" 0 0 sync-zg >/dev/null
    "$BG_POKE" "$dev" 0 0 fill-bitmap >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/noop_free_dirties
    echo 1 >/sys/module/cetrafs/parameters/release_noop_free
    mark="$(dmesg_mark)"
    echo 2 >/sys/module/cetrafs/parameters/hb_interval_secs
    # The tick already queued still runs on the old 30 s interval, so the
    # release can come a whole old interval after this: wait past it (a
    # KASAN kernel released at 30 s, just outside a 30 s wait).
    for _ in $(seq 1 120); do
        dmesg_since "$mark" | grep -q "BG 1 handed back" && { rel=1; break; }
        sleep 0.5
    done
    dmesg_since "$mark" | grep -q "BG 1 release: a free of already-free block" && noop=1
    g="$("$BG_POKE" "$img" 1 --dump)"
    st="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$g")"
    off="$(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$g")"
    lba=$((st + off))
    # the next owner allocates its first 64 blocks: on the device, not through this node
    printf '\377\377\377\377\377\377\377\377' | dd of="$img" bs=1 seek=$((lba * 4096)) conv=notrunc status=none
    blockdev --flushbufs "$dev"
    sync
    got="$(dd if="$img" bs=1 skip=$((lba * 4096)) count=8 status=none | od -An -tx1 | tr -d ' \n')"
    echo 0 >/sys/module/cetrafs/parameters/noop_free_dirties
    echo 0 >/sys/module/cetrafs/parameters/release_noop_free
    echo 30 >/sys/module/cetrafs/parameters/hb_interval_secs
    ct_umount "$MNT"
    echo "released=$rel noop=$noop peer=$got"
}

get() { sed -n "s/.*$1=\([0-9a-f]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (old free and drop): $C"
for v in "$R" "$C"; do
    [ "$(get released "$v")" = 1 ] && [ "$(get noop "$v")" = 1 ] ||
        { fail "setup: the group was not released with the no-op free inside ($v)"; ct_exit; }
done
pass "setup: Block Group 1 was handed back with a no-op free inside the window"
[ "$(get peer "$R")" = ffffffffffffffff ] && pass "1: the next owner's bits survived this node's writeback" ||
    fail "1: the next owner's bits read $(get peer "$R") after this node's writeback"
[ "$(get peer "$C")" != ffffffffffffffff ] &&
    pass "control: the old free and drop wrote the all-clear image over them ($(get peer "$C"))" ||
    fail "control: the next owner's bits survived the old code too -- the suite cannot see the bug"
ct_exit
