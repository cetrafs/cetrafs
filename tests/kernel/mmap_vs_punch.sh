#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a page fault must not re-instantiate folios over blocks a punch is freeing
#
# Hole punch drops the cached folios over the range and then frees the
# blocks behind them. Both steps run under inode_lock -- which a page
# fault does not take, and never can (it already holds mmap_lock, and
# i_rwsem is taken before mmap_lock everywhere else).
#
# So a fault landing between the two steps re-reads the folio through
# the extents that are still there, and its buffers go on pointing at
# those blocks after the punch frees them. Writeback then writes the
# mapping's bytes into blocks the file no longer owns -- free space the
# allocator hands to the next file that asks.
#
# mapping->invalidate_lock is the lock built for exactly this: faults
# take it shared (filemap_fault for a read, cetrafs_page_mkwrite for a
# store), punch/truncate/fallocate take it exclusively around the drop
# and the free.
#
# WHAT IS MEASURED, and why not the obvious thing: the obvious test is
# to let another file claim the freed blocks and look for the marker in
# it. That cannot work here -- a punch's free-count delta only reaches
# the allocator at a durability boundary, and on a full volume the next
# such boundary is the victim's own close, by which time its stale
# writeback has already happened. (Measured: free_data_blocks stays 0
# after the punch and jumps to 193 the moment the mapping closes.)
#
# So the device is read directly instead. Every block the file owned
# before the punch and does not own after is free space; the marker
# byte 0xEE exists nowhere but in the mapping, so finding it in one of
# those blocks is proof that writeback wrote where it must not. No full
# volume, no second file, no timing assumption in the assertion itself.
#
# punch_pagecache_delay_ms holds the window open. In production it is a
# tree build plus a synchronous record write, which a real workload hits
# on its own; a test needs it every time.
#
# Discrimination: drop the filemap_invalidate_lock() around the punch
# and blocks the file no longer owns come back full of 0xEE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 mmappunch)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmappunch)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

MAPFILE_BEFORE="$(ct_tmp mmappunch_before)"
MAPFILE_AFTER="$(ct_tmp mmappunch_after)"

ct_param_set punch_pagecache_delay_ms 600

RC=0
python3 - "$MNT" "$MAPFILE_BEFORE" "$MAPFILE_AFTER" <<'PY' || RC=$?
import ctypes, mmap, os, subprocess, sys, time

libc = ctypes.CDLL("libc.so.6", use_errno=True)
PUNCH = 0x02 | 0x01                       # PUNCH_HOLE | KEEP_SIZE
mnt, before_path, after_path = sys.argv[1], sys.argv[2], sys.argv[3]
SZ = 1 << 20
MARKED = 256 * 1024
# The child marks only the FIRST quarter. With the lock in place those
# stores block until the punch is done and then allocate, so those
# blocks are owned again and are excluded from the check below -- as
# they should be, a store after a punch is an ordinary write. Marking
# the whole range instead made the file re-own all 256 blocks and left
# nothing to check, which is how the first version of this suite ended
# up asserting over an empty set.
path = mnt + "/victim"


def physical_blocks(p):
    """Absolute device blocks the file owns right now, via FIEMAP."""
    out = subprocess.run(["filefrag", "-v", "-b4096", p], capture_output=True, text=True).stdout
    blocks = set()
    for line in out.splitlines():
        parts = line.replace("..", " ").replace(":", " ").split()
        if len(parts) >= 6 and parts[0].isdigit():
            phys_start, length = int(parts[3]), int(parts[5])
            blocks.update(range(phys_start, phys_start + length))
    return blocks


f = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(f, b'A' * SZ, 0)
os.fsync(f)
os.sync()
before = physical_blocks(path)
if len(before) != SZ // 4096:
    print("the victim does not map %d blocks (%d) -- setup is wrong" % (SZ // 4096, len(before)))
    sys.stdout.flush()
    os._exit(2)

m = mmap.mmap(f, SZ, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
pid = os.fork()
if pid == 0:
    time.sleep(0.25)                      # inside the window the delay holds open
    for off in range(0, MARKED, 4096):
        m[off] = 0xEE
    os._exit(0)
libc.fallocate(f, PUNCH, ctypes.c_long(0), ctypes.c_long(SZ))
os.waitpid(pid, 0)

try:
    m.flush()                             # the stale writeback, if there is one
except OSError:
    pass
m.close()
try:
    os.fsync(f)
except OSError:
    pass
after = physical_blocks(path)
os.close(f)
os.sync()

open(before_path, "w").write(" ".join(str(b) for b in sorted(before)))
open(after_path, "w").write(" ".join(str(b) for b in sorted(after)))
print("blocks owned before the punch: %d, after: %d, given up: %d"
      % (len(before), len(after), len(before - after)))
if not (before - after):
    print("the punch gave up nothing -- there is no freed block to check")
    sys.stdout.flush()
    os._exit(2)
sys.stdout.flush()
os._exit(0)
PY

ct_param_set punch_pagecache_delay_ms 0
[ "$RC" = 2 ] && fail "setup did not produce a freed range -- the assertion could not be made"

ct_umount "$MNT"

# Read the device itself: anything still holding the marker in a block
# the file gave up was written there by the mapping, after the punch had
# handed that block back to the allocator.
RC2=0
python3 - "$IMG" "$MAPFILE_BEFORE" "$MAPFILE_AFTER" <<'PY' || RC2=$?
import sys

img, before_path, after_path = sys.argv[1], sys.argv[2], sys.argv[3]
before = set(int(x) for x in open(before_path).read().split())
after = set(int(x) for x in open(after_path).read().split())
given_up = sorted(before - after)

dirty = []
with open(img, "rb") as d:
    for b in given_up:
        d.seek(b * 4096)
        if b'\xee' in d.read(4096):
            dirty.append(b)
print("freed blocks checked: %d, holding the mapping's marker: %d %s"
      % (len(given_up), len(dirty), dirty[:4] if dirty else ""))
sys.stdout.flush()
sys.exit(1 if dirty else 0)
PY

[ "$RC2" = 0 ] &&
    pass "no block the punch freed was written to by the mapping" ||
    fail "the mapping's writeback landed in blocks the punch had already freed -- the next file to allocate them gets them overwritten"

ct_fsck "$DEV" >/dev/null || fail "fsck found faults after the race"
pass "fsck clean"

ct_exit
