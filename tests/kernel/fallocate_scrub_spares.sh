#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub never reclaims the blocks a fallocate holds before its publish
#
# cetrafs_do_allocate() allocates a preallocation block by block, keeps
# the blocks in a local array and publishes them in one record CAS at the
# end -- for a large image, many seconds later. Until then they are
# bitmap-allocated and named by nothing on the device: exactly what the
# scrub frees. Its two-pass argument assumes an allocation is committed
# within milliseconds, and its allocation-count gate abandons only a Block
# Group allocated in during the cycle -- a group the fallocate has
# finished with stays still. So the scrub freed the blocks, the allocator
# handed them to another file, and the publish named them too: two files
# sharing blocks (audit 2026-11-06 H2). The blocks are now registered with
# the scrub's reservation registry for the life of the call.
#
# Staged on one node: fallocate_block_delay_us stretches the call across
# several fast scrub cycles, and scrub_ignore_alloc_seq stands the
# allocation-count gate down -- the group-finished case, and it leaves the
# registry as the only thing that can keep the blocks. Asserted: at least
# two cycles ran while the call held its blocks (else nothing was
# measured), the scrub reclaimed nothing, the file reads back as zeros
# over its whole length, and fsck is clean.
#
# DISCRIMINATION: with the registry step removed the scrub reclaims the
# call's blocks and fsck reports them free in the bitmap but named by the
# file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in fallocate_block_delay_us scrub_ignore_alloc_seq; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done

BLOCKS=3000 # at 3-6 ms a block: 9-18 s, several 3 s scrub cycles
DEV="$(ct_dev 900 fscrub)"
MNT="$(ct_mnt fscrub)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
PROC="$(ct_procdir "$DEV")"
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }
cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }

ct_param_set scrub_ignore_alloc_seq 1
ct_param_set fallocate_block_delay_us 3000
python3 - "$MNT/img" "$BLOCKS" <<'PY' &
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
if libc.fallocate(f, 0, ctypes.c_long(0), ctypes.c_long(int(sys.argv[2]) * 4096)) != 0:
    sys.exit("fallocate: " + os.strerror(ctypes.get_errno()))
os.close(f)
PY
PID=$!
sleep 1
R0="$(reclaimed)"
C0="$(cycles)"
ct_param_set scrub 1
wait_for 60 '[ "$(( $(cycles) - '"$C0"' ))" -ge 2 ] || ! kill -0 '"$PID"' 2>/dev/null' || true
RUNNING=0
kill -0 "$PID" 2>/dev/null && RUNNING=1
NC=$(($(cycles) - C0))
wait "$PID" && RC=0 || RC=$?
GOT=$(($(reclaimed) - R0))
ct_param_set scrub 0
ct_param_set fallocate_block_delay_us 0
ct_param_set scrub_ignore_alloc_seq 0

[ "$RUNNING" = 1 ] && [ "$NC" -ge 2 ] ||
    { fail "setup: the fallocate did not span two scrub cycles (cycles $NC, still running: $RUNNING)"; ct_exit; }
[ "$RC" = 0 ] || fail "setup: the fallocate itself failed (rc $RC)"
[ "$GOT" = 0 ] && pass "the scrub reclaimed nothing a running fallocate held ($NC cycles)" ||
    fail "the scrub reclaimed $GOT block(s) a running fallocate held -- the allocator may hand them out again"
SZ="$(stat -c %s "$MNT/img")"
[ "$SZ" = $((BLOCKS * 4096)) ] || fail "setup: the file is $SZ bytes, not $((BLOCKS * 4096))"
cmp -s -n "$SZ" "$MNT/img" /dev/zero && pass "the preallocated file reads back as zeros" ||
    fail "the preallocated file does not read back as zeros"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
