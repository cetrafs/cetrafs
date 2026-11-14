#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an fsync's conversion does not hold the file's locks across its device flush
#
# fsync of a file with buffered writes into preallocated blocks converts
# them (cetrafs_convert_pending()): data written back, the device cache
# flushed, then the extents marked written. That whole span ran under the
# file's inode_lock and invalidate_lock, both exclusive, so every write(2)
# and every fault on the file waited for the flush -- on a slow array, a
# writer stalled for the whole boundary (audit FD-7).
#
# The flush now runs after the locks are released, and the converted
# extents are published under them. Test knob publish_flush_stall_ms makes
# every publish-point flush slow, and the rig checks that a write(2) to the
# same file, issued while an fsync of it is stuck in its flush, is not
# held for that flush:
#   1. as shipped: the write completes long before the stalled flush does;
#   2. control convert_flush_under_lock=1 (TEST ONLY) puts the conversion's
#      flush back under the locks: the write must wait for it.
# Setup: the fsync must really be stalled (it takes at least two stalls),
# or the write proves nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/convert_flush_under_lock ] || { skip "convert_flush_under_lock is missing"; ct_exit; }
MNT="$(ct_mnt fcs)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set convert_flush_under_lock 0
ct_param_set publish_flush_stall_ms 0

STALL_MS=2000
DEV="$(ct_loop "$(ct_image 560 fcs1)")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# probe <file> <knob>: prints "<write_ms> <fsync_ms>". The writer goes in
# while the fsync sleeps in its first stalled flush.
probe() {
    echo "$2" >/sys/module/cetrafs/parameters/convert_flush_under_lock
    echo "$STALL_MS" >/sys/module/cetrafs/parameters/publish_flush_stall_ms
    python3 - "$MNT/$1" <<'PY'
import os, sys, threading, time
path = sys.argv[1]
fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
os.posix_fallocate(fd, 0, 64 * 4096)
# Blocks 0..31 buffered and pending: the fsync below converts all of them.
for b in range(32):
    os.pwrite(fd, (b"A%03d" % b) * 1024, b * 4096)
fsync_ms = [0.0]
def do_fsync():
    t = time.monotonic()
    os.fsync(fd)
    fsync_ms[0] = (time.monotonic() - t) * 1000
th = threading.Thread(target=do_fsync)
th.start()
time.sleep(0.5)  # the fsync is now in its conversion, stalled in a flush
t = time.monotonic()
os.pwrite(fd, b"W" * 4096, 40 * 4096)
write_ms = (time.monotonic() - t) * 1000
th.join()
os.close(fd)
print("%d %d" % (write_ms, fsync_ms[0]))
PY
    echo 0 >/sys/module/cetrafs/parameters/publish_flush_stall_ms
}

read -r W F <<<"$(probe shipped 0)"
[ "$F" -ge $((STALL_MS * 2 - 200)) ] && pass "setup: the fsync sat in $(( F / STALL_MS )) stalled flushes (${F} ms)" ||
    { fail "setup: the fsync took ${F} ms -- it never reached the stalled flushes"; ct_exit; }
[ "$W" -lt $((STALL_MS / 2)) ] && pass "as shipped: a write during the fsync took ${W} ms, not held for the flush" ||
    fail "as shipped: a write during the fsync took ${W} ms -- the conversion holds the file's locks across its flush"

read -r CW CF <<<"$(probe control 1)"
echo 0 >/sys/module/cetrafs/parameters/convert_flush_under_lock
[ "$CW" -ge $((STALL_MS / 2)) ] && pass "control: with the flush under the locks, the write waited ${CW} ms" ||
    fail "control: the write took ${CW} ms with the flush under the locks -- the rig cannot see the stall"

ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$out" && fail "fsck: $(grep '^ERR' <<<"$out" | head -2)" || pass "fsck clean"
ct_exit
