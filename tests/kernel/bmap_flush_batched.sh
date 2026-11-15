#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the boundary bitmap flush sends its blocks together, and a caller queued behind it can be killed
#
# Every fsync, close and first-touch append that allocated flushes the
# allocation bitmaps of the groups it marked before publishing, one
# flush at a time per node. The flush wrote each bitmap block with its
# own synchronous write: ~38 ms a block on a SAN, minutes for a large
# preallocation, and every other caller of the node waited for it in D
# state, unkillable (audit 2026-11-15 B-29, M-8). The blocks now go
# out under one plug and are waited for together, and the wait for the
# flush in flight is killable.
#
# A. On dm-delay (40 ms a write), a 5 GiB fallocate marks ~40 bitmap
#    blocks: its flush is timed.
#      setup: the serial control wrote at least 30 blocks (one batch each);
#      1. one or two batches, saving at least half a delay per block
#         against the serial control; fsck clean.
# B. A flush is held (alloc_flush_stall_ms); a second writer's fsync
#    queues behind it and is sent SIGKILL:
#      2. it is gone within a second, long before the held flush ends.
#
# DISCRIMINATION: bmap_flush_serial=1 (A: a delay per block);
# bmap_flush_unkillable=1 (B: the killed fsync waits out the flush).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bmap_flush_serial bmap_flush_unkillable alloc_flush_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_delay 2>/dev/null || true
grep -q '^delay' <(dmsetup targets) || { skip "no dm delay target"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt bfb)"
ct_track mnt "$MNT"
ct_param_set bmap_flush_serial 0
ct_param_set bmap_flush_unkillable 0
ct_param_set alloc_flush_stall_ms 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
DELAY_MS=40
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# A <serial 0|1> -> RES
round_a() {
    local loop dm dev proc t0 t1 b0 b1 out
    loop="$(ct_loop "$(ct_image 6400 "bfb$1")")"
    dm="cetra-bfb$$-$1"
    dmsetup create "$dm" --table "0 $(blockdev --getsz "$loop") delay $loop 0 0 $loop 0 $DELAY_MS"
    ct_track dm "$dm"
    dev="/dev/mapper/$dm"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    sync
    echo "$1" >$P/bmap_flush_serial
    b0="$(sed -n 's/^bmap_flush_batches: //p' "$proc/info")"
    t0="$(date +%s%N)"
    fallocate -l 5G "$MNT/big"
    t1="$(date +%s%N)"
    b1="$(sed -n 's/^bmap_flush_batches: //p' "$proc/info")"
    echo 0 >$P/bmap_flush_serial
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR|leaked' <<<"$out" && out=ERR || out=clean
    dmsetup remove "$dm"
    RES="batches=$((b1 - b0)) ms=$(((t1 - t0) / 1000000)) fsck=$out"
}

# B <unkillable 0|1> -> RES
round_b() {
    local dev pa pb t0 gone=0
    dev="$(ct_loop "$(ct_image 560 "bfk$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/bmap_flush_unkillable
    echo 5000 >$P/alloc_flush_stall_ms
    dd if=/dev/zero of="$MNT/a" bs=4096 count=64 conv=fsync status=none &
    pa=$!
    sleep 1
    # the flush is held with its mark taken: a second writer's fsync queues
    dd if=/dev/zero of="$MNT/b" bs=4096 count=64 conv=fsync status=none &
    pb=$!
    sleep 1
    t0="$(date +%s%N)"
    kill -9 "$pb" 2>/dev/null || true
    for _ in $(seq 1 60); do
        kill -0 "$pb" 2>/dev/null || { gone=1; break; }
        sleep 0.1
    done
    RES="gone_ms=$(((($(date +%s%N) - t0)) / 1000000)) gone=$gone stalled=$(cat $P/alloc_flush_stall_ms)"
    wait "$pa" || true
    wait "$pb" 2>/dev/null || true
    echo 0 >$P/alloc_flush_stall_ms
    echo 0 >$P/bmap_flush_unkillable
    ct_umount "$MNT"
}

round_a 1
AC="$RES"
log "A control (serial): $AC"
round_a 0
A="$RES"
log "A batched: $A"
N="$(get batches "$AC")"
[ "$N" -ge 30 ] || { fail "setup: the fallocate's flush wrote only $N bitmap blocks ($AC)"; ct_exit; }
# The fallocate writes more than its bitmaps (its tree, its record): the
# flush's share is what batching saves against the serial control.
SAVED=$(($(get ms "$AC") - $(get ms "$A")))
[ "$(get batches "$A")" -le 2 ] && [ "$SAVED" -ge $((N * DELAY_MS / 2)) ] && [ "$(get fsck "$A")" = clean ] &&
    pass "1: $N bitmap blocks flushed in $(get batches "$A") batch(es): $SAVED ms saved at $DELAY_MS ms a write; fsck clean" ||
    fail "1: $A against $AC (a delay per block is $((N * DELAY_MS)) ms)"
[ "$(get ms "$AC")" -ge $((N * DELAY_MS)) ] && pass "A control: serial, the same fallocate took $(get ms "$AC") ms" ||
    fail "A control: serial took only $(get ms "$AC") ms -- the suite cannot see the difference"

round_b 1
BC="$RES"
log "B control (unkillable): $BC"
round_b 0
B="$RES"
log "B: $B"
[ "$(get stalled "$B")" = 0 ] || { fail "setup: the flush stall was never reached ($B)"; ct_exit; }
[ "$(get gone "$B")" = 1 ] && [ "$(get gone_ms "$B")" -lt 1000 ] &&
    pass "2: the fsync queued behind the held flush died $(get gone_ms "$B") ms after SIGKILL" || fail "2: $B"
[ "$(get gone_ms "$BC")" -ge 1500 ] &&
    pass "B control: unkillable, the killed fsync waited $(get gone_ms "$BC") ms for the flush" ||
    fail "B control: the killed fsync left at once ($BC) -- the suite does not queue it behind the flush"
ct_exit
