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
#       scrub reads -- keeps the blocks. The foreign case on one node.
#
# Each part asserts that two cycles looked inside the stall (completed,
# or stopped by the flag -- scrub_inflight_skips) else nothing was
# measured, and that the operation then freed what it dropped. After
# the stalls a cycle must complete again: the flag comes back down.
#
# DISCRIMINATION: without the flag, (1) and (2) reclaim the dropped
# blocks inside the stall; with the row flag never written, (3) does.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in punch_pagecache_delay_ms truncate_free_stall_ms scrub_ignore_local_frees; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done

BLOCKS=2048
STALL=9000 # ms: room for two 2 s scrub cycles with a 1 s gap
DEV="$(ct_dev 900 sinfl)"
MNT="$(ct_mnt sinfl)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
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
staged "punch, registry row only" punch_pagecache_delay_ms punch
ct_param_set scrub_ignore_local_frees 0
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
