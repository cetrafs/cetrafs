#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# held bitmap blocks are written together, not one synchronous write each
#
# Since A-15 the allocation bitmaps are held from block-layer writeback
# and only cetrafs writes them. Frees are not marked for the boundary
# flush, so the held flush writes them -- and it wrote one block at a
# time, each waited for before the next: ~38 ms a block on a SAN, about
# five minutes for the ~8,192 bitmap blocks of a 1 TiB image deleted,
# with the pending-free drain, a Zone Group release and every sync
# queued behind it. They are now sent a batch at a time under one plug,
# then waited for.
#
# A loop device costs nothing per write, so the volume sits on dm-delay
# (40 ms per write). A file fallocated over ~40 bitmap blocks' worth of
# space is deleted, and the sync that writes the held frees is timed.
#   setup: the frees left at least 30 bitmap blocks held (counted by the
#          serial control, where each block is a batch of its own);
#   1. the sync took well under one delay per held block;
#   2. after a remount fsck is clean (the frees reached the device).
#
# DISCRIMINATION: held_flush_serial=1: 1 fails (a delay per block).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/held_flush_serial ] || { skip "held_flush_serial is missing"; ct_exit; }
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_delay 2>/dev/null || true
grep -q '^delay' <(dmsetup targets) || { skip "no dm delay target"; ct_exit; }
MNT="$(ct_mnt hfb)"
ct_track mnt "$MNT"
ct_param_set held_flush_serial 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
DELAY_MS=40

# <serial 0|1> -> "held=<blocks freed into held bitmaps> ms=<sync time> fsck=<clean|ERR>"
round() {
    local loop dm dev proc ms t0 t1 out h0 h1
    loop="$(ct_loop "$(ct_image 6400 "hfb$1")")"
    dm="cetra-hfb$$-$1"
    dmsetup create "$dm" --table "0 $(blockdev --getsz "$loop") delay $loop 0 0 $loop 0 $DELAY_MS"
    ct_track dm "$dm"
    dev="/dev/mapper/$dm"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    fallocate -l 5G "$MNT/big"
    sync
    echo "$1" >/sys/module/cetrafs/parameters/held_flush_serial
    h0="$(sed -n 's/^held_flush_batches: //p' "$proc/info")"
    rm -f "$MNT/big"
    t0="$(date +%s%N)"
    sync -f "$MNT"
    t1="$(date +%s%N)"
    h1="$(sed -n 's/^held_flush_batches: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/held_flush_serial
    ms=$(((t1 - t0) / 1000000))
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR|leaked' <<<"$out" && out=ERR || out=clean
    dmsetup remove "$dm"
    echo "batches=$((h1 - h0)) ms=$ms fsck=$out"
}
get() { sed -n "s/.*$1=\([0-9a-z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "batched: $R"
C="$(round 1)"
log "control (serial): $C"
# serial, each held block is a batch of one: the control counts them
HELD="$(get batches "$C")"
[ "$HELD" -ge 30 ] && [ "$(get batches "$R")" -ge 1 ] || { fail "setup: the frees did not leave 30 bitmap blocks held ($R | $C)"; ct_exit; }
pass "setup: the delete freed into $HELD bitmap blocks, written in $(get batches "$R") batch(es)"
LIMIT=$((HELD * DELAY_MS / 3))
[ "$(get ms "$R")" -lt "$LIMIT" ] && pass "1: the sync took $(get ms "$R") ms for $HELD held blocks at $DELAY_MS ms a write" ||
    fail "1: the sync took $(get ms "$R") ms, a delay per block is $((HELD * DELAY_MS)) ms"
[ "$(get fsck "$R")" = clean ] && pass "2: fsck clean after the frees" || fail "2: fsck: $(get fsck "$R")"
[ "$(get ms "$C")" -ge "$LIMIT" ] && pass "control: serial, the same sync took $(get ms "$C") ms" ||
    fail "control: serial took only $(get ms "$C") ms -- the suite cannot see the difference"
ct_exit
