#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub never frees a block a publish has dropped and is about to free
#
# Truncate and punch publish the record that drops their blocks FIRST and
# free them after (rule 21). In between, the blocks are bitmap-set and
# named by nothing -- exactly what the scrub frees -- and for a large,
# fragmented file the frees run long: one queue CAS per extent when a
# peer owns the Zone Group. A scrub cycle whose first pass came after the
# publish freed them, then the truncating node freed them again, by then
# perhaps another file's (audit 2026-11-06, the N2 sweep's finding A).
#
# A node with such frees in flight now says so in its registry row
# (frees_inflight) before the publish, and the scrub abandons a cycle
# while any node's row, or this node's own count, says so.
#
#   (1) punch, stalled between its publish and its frees: the scrub runs
#       two cycles and reclaims nothing; fsck is clean.
#   (2) truncate, the same.
#   (3) punch again with this node's in-memory count stood down
#       (scrub_ignore_local_frees): only the registry row -- what a PEER's
#       scrub reads -- keeps the blocks. The foreign case on one node:
#       every group here is this node's own, and only a free outside
#       them is announced, so frees_announce_all puts the row in play.
#   (4) a punch of blocks in this node's own groups is NOT announced
#       (frees_announced stays put): no peer's scrub judges those
#       blocks, and announcing them stopped every scrub in the cluster
#       whenever any node punched its own image. Control: with
#       frees_announce_all the same punch is announced.
#
#   (5) preallocation over a fragmented file's holes rebuilds its tree:
#       stalled between that publish and the old tree's frees, the scrub
#       reclaims none of the old leaves and interiors -- with this node's
#       count, and with only the registry row (audit 2026-11-15 B-31).
#
# Each part asserts that two cycles looked inside the stall (completed,
# or stopped by the flag -- scrub_inflight_skips) else nothing was
# measured, and that the operation then freed what it dropped. After
# the stalls a cycle must complete again: the flag comes back down.
#
# DISCRIMINATION: without the flag, (1) and (2) reclaim the dropped
# blocks inside the stall; with the row flag never written, (3) does;
# (4) carries its own control; (5) with falloc_frees_unannounced=1 (the
# frees unannounced, as before) reclaims the old tree's blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in punch_pagecache_delay_ms truncate_free_stall_ms scrub_ignore_local_frees frees_announce_all \
    falloc_free_stall_ms falloc_frees_unannounced; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done

BLOCKS=2048
STALL=9000 # ms: room for two 2 s scrub cycles with a 1 s gap
DEV="$(ct_dev 900 sinfl)"
MNT="$(ct_mnt sinfl)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set hb_interval_secs 2
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
PROC="$(ct_procdir "$DEV")"
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }
# a cycle that looked: completed, or stopped by frees in flight
cycles() { echo $(($(sed -n 's/^scrub_cycles: //p' "$PROC/info") + $(sed -n 's/^scrub_inflight_skips: //p' "$PROC/info"))); }
free_blocks() { stat -f -c %f "$MNT"; }

# <label> <knob> <command...>: run the command in the background with
# the knob stalling it after its publish, the scrub on throughout.
staged() {
    local label="$1" knob="$2" pid r0 c0 nc got running f0 f1
    shift 2
    dd if=/dev/urandom of="$MNT/f" bs=4096 count="$BLOCKS" status=none
    sync
    f0="$(free_blocks)"
    ct_param_set "$knob" "$STALL"
    "$@" &
    pid=$!
    sleep 1
    r0="$(reclaimed)"
    c0="$(cycles)"
    ct_param_set scrub 1
    wait_for 30 '[ "$(( $(cycles) - '"$c0"' ))" -ge 2 ] || ! kill -0 '"$pid"' 2>/dev/null' || true
    running=0
    kill -0 "$pid" 2>/dev/null && running=1
    nc=$(($(cycles) - c0))
    got=$(($(reclaimed) - r0))
    ct_param_set scrub 0
    wait "$pid" || fail "$label: the operation itself failed"
    ct_param_set "$knob" 0
    sync
    f1="$(free_blocks)"
    [ "$running" = 1 ] && [ "$nc" -ge 2 ] ||
        { fail "setup ($label): the stall did not span two scrub cycles (cycles $nc, still running: $running)"; return; }
    [ $((f1 - f0)) -ge $((BLOCKS / 2)) ] ||
        { fail "setup ($label): the operation freed $((f1 - f0)) blocks, not the ~$BLOCKS it dropped"; return; }
    [ "$got" = 0 ] && pass "$label: the scrub reclaimed nothing the operation had dropped and not yet freed ($nc cycles)" ||
        fail "$label: the scrub reclaimed $got block(s) the operation was about to free itself -- freed twice"
    rm -f "$MNT/f"
}
punch() { python3 - "$MNT/f" "$BLOCKS" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
# PUNCH_HOLE | KEEP_SIZE over all but the first and last block
if libc.fallocate(f, 3, ctypes.c_long(4096), ctypes.c_long((int(sys.argv[2]) - 2) * 4096)) != 0:
    sys.exit("punch: " + os.strerror(ctypes.get_errno()))
os.close(f)
PY
}
shrink() { truncate -s 4096 "$MNT/f"; }

MARK="$(dmesg_mark)"
staged "punch" punch_pagecache_delay_ms punch
staged "truncate" truncate_free_stall_ms shrink
ct_param_set scrub_ignore_local_frees 1
ct_param_set frees_announce_all 1
staged "punch, registry row only" punch_pagecache_delay_ms punch
ct_param_set frees_announce_all 0
ct_param_set scrub_ignore_local_frees 0

# (5) <label>: a depth-2 file (every other block of 6000 written), its
# holes preallocated: the rebuild's old tree is freed after the publish,
# behind the stall. Sets GOT (blocks the scrub reclaimed in the stall).
prealloc_staged() {
    local label="$1" pid r0 c0 nc running depth
    python3 -I - "$MNT/g" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.urandom(4096)
for i in range(0, 6000, 2):
    os.pwrite(fd, b, i * 4096)
os.fsync(fd); os.close(fd)
PY
    sync
    ct_param_set falloc_free_stall_ms "$STALL"
    fallocate -o 0 -l $((6000 * 4096)) "$MNT/g" &
    pid=$!
    sleep 1
    r0="$(reclaimed)"
    c0="$(cycles)"
    ct_param_set scrub 1
    wait_for 30 '[ "$(( $(cycles) - '"$c0"' ))" -ge 2 ] || ! kill -0 '"$pid"' 2>/dev/null' || true
    running=0
    kill -0 "$pid" 2>/dev/null && running=1
    nc=$(($(cycles) - c0))
    GOT=$(($(reclaimed) - r0))
    ct_param_set scrub 0
    wait "$pid" || fail "$label: the preallocation itself failed"
    ct_param_set falloc_free_stall_ms 0
    sync
    rm -f "$MNT/g"
    [ "$running" = 1 ] && [ "$nc" -ge 2 ] ||
        { fail "setup ($label): the stall did not span two scrub cycles (cycles $nc, still running: $running)"; GOT=x; return; }
    log "$label: $nc cycles in the stall, $GOT block(s) reclaimed"
}
prealloc_staged "preallocation"
[ "$GOT" = 0 ] && pass "preallocation: the scrub reclaimed none of the old tree's blocks before their free" ||
    fail "preallocation: the scrub reclaimed $GOT block(s) of the old tree -- freed twice"
ct_param_set scrub_ignore_local_frees 1
ct_param_set frees_announce_all 1
prealloc_staged "preallocation, registry row only"
[ "$GOT" = 0 ] && pass "preallocation, registry row only: the row kept the old tree's blocks" ||
    fail "preallocation, registry row only: the scrub reclaimed $GOT block(s) of the old tree"
ct_param_set falloc_frees_unannounced 1
prealloc_staged "preallocation, unannounced (control)"
ct_param_set falloc_frees_unannounced 0
ct_param_set frees_announce_all 0
ct_param_set scrub_ignore_local_frees 0
[ "$GOT" != x ] && [ "$GOT" -gt 0 ] && pass "preallocation, control: unannounced, the scrub reclaimed $GOT block(s) of the old tree" ||
    fail "preallocation, control: unannounced, the scrub reclaimed nothing -- the case does not reach the old tree"
# The control freed blocks the scrub had already freed: fsck below would
# report that, so the volume is rebuilt for what follows.
ct_umount "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
MARK="$(dmesg_mark)"

# (4) <label>: a plain punch of this node's own blocks; sets ANN (begins
# announced to peers) and FREED (blocks it gave back).
own_punch() {
    local a0 f0
    dd if=/dev/urandom of="$MNT/f" bs=4096 count="$BLOCKS" status=none
    sync
    a0="$(sed -n 's/^frees_announced: //p' "$PROC/info")"
    f0="$(free_blocks)"
    punch
    sync
    ANN=$(($(sed -n 's/^frees_announced: //p' "$PROC/info") - a0))
    FREED=$(($(free_blocks) - f0))
    rm -f "$MNT/f"
    log "$1: $ANN announced, $FREED blocks freed"
}
ct_param_set frees_announce_all 1
own_punch "own groups, control"
ct_param_set frees_announce_all 0
[ "$FREED" -ge $((BLOCKS / 2)) ] || fail "setup (own groups, control): the punch freed $FREED blocks"
[ "$ANN" -ge 1 ] && pass "own groups, control: announcing every free, the punch is announced" ||
    fail "own groups, control: not announced even with frees_announce_all -- the counter sees nothing"
own_punch "own groups"
[ "$FREED" -ge $((BLOCKS / 2)) ] || fail "setup (own groups): the punch freed $FREED blocks"
[ "$ANN" = 0 ] && pass "own groups: a punch of this node's own blocks is not announced to peers" ||
    fail "own groups: the punch was announced ($ANN) -- every peer's scrub stops for it"
# The flag comes down on a heartbeat once nothing is in flight, and the
# scrub runs whole cycles again -- else this would be a scrub turned off.
C0="$(sed -n 's/^scrub_cycles: //p' "$PROC/info")"
ct_param_set scrub 1
wait_for 60 '[ "$(sed -n "s/^scrub_cycles: //p" "'"$PROC/info"'")" -gt '"$C0"' ]' &&
    pass "the scrub completes cycles again once the operations are done" ||
    fail "no scrub cycle completed in 60 s after the operations ended -- the frees-in-flight flag stayed up"
ct_param_set scrub 0
dmesg_since "$MARK" | grep -iE 'double free|already free|corrupt' && fail "the kernel logged a free of a free block" ||
    pass "no free of an already-free block was logged"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
