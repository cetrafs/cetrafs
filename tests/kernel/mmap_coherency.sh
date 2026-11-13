#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a MAP_SHARED mapping and read(2)/write(2) of the same range agree, and msync is durable
#
# The mmap suites so far check the fault path as an allocator (punch,
# write, O_DIRECT, EOF, ENOSPC). Nothing checked what a mapping SEES:
# a store that read(2) must return, a write(2) that a mapping must show,
# a store read back after a concurrent reader, and msync(MS_SYNC) leaving
# the bytes on the device.
#
# Three parts, all by content:
#   1. same-node coherency both ways: write(2) then load through the
#      mapping; store through the mapping then pread(2) -- no msync between.
#   2. a writer process stores a new generation into every page while the
#      parent pread(2)s the same range. Every byte the reader sees must be
#      one some generation wrote; after the writer finishes, the file reads
#      back as the last generation.
#   3. msync(MS_SYNC) then unmount and remount: the last generation is what
#      the device holds (no page cache answers).
#
# No knob here can break MAP_SHARED coherency without inventing a new
# fault, so this suite has NO negative control. Its assertions are content
# checks against a model, and they are recorded as such in
# docs/internal/TEST-COVERAGE-GAPS.md (section 2).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PAGES=32
IMG="$(ct_image 560 mmapcoh)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmapcoh)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

RC=0
python3 - "$MNT" "$PAGES" <<'PY' || RC=$?
import mmap, os, sys
mnt, pages = sys.argv[1], int(sys.argv[2])
SZ = pages * 4096
path = mnt + "/cohere"

def fill(gen):
    return bytes([gen]) * SZ

# Part 1: write(2) -> mapping, and mapping -> pread(2), with no msync.
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
os.write(fd, fill(1))
mm = mmap.mmap(fd, SZ, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
if mm[:] != fill(1):
    print("part1: the mapping does not show write(2)'s bytes"); sys.exit(1)
mm[:] = fill(2)
if os.pread(fd, SZ, 0) != fill(2):
    print("part1: pread(2) does not show the mapping's store"); sys.exit(1)
print("part1 ok")

# Part 2: a child stores generations 3..N into every page; the parent
# reads the range concurrently. A byte may be any generation's value
# (pages are not stored atomically), but never something no store wrote.
GENS = 40
pid = os.fork()
if pid == 0:
    cfd = os.open(path, os.O_RDWR)
    cm = mmap.mmap(cfd, SZ, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    for g in range(3, 3 + GENS):
        cm[:] = fill(g)
        cm.flush()
    cm.close()
    os._exit(0)
bad = None
seen_max = 2
while True:
    done = os.waitpid(pid, os.WNOHANG)[0] == pid
    data = os.pread(fd, SZ, 0)
    vals = set(data)
    if max(vals) > 3 + GENS - 1 or min(vals) < 1:
        bad = "a reader saw byte values %s no store wrote" % sorted(vals)[:4]
        break
    seen_max = max(seen_max, max(vals))
    if done:
        break
if bad:
    print("part2: " + bad); sys.exit(1)
last = 3 + GENS - 1
if os.pread(fd, SZ, 0) != fill(last):
    print("part2: after the writer finished the file is not its last generation"); sys.exit(1)
print("part2 ok (reader saw up to generation %d)" % seen_max)

# Part 3: msync(MS_SYNC) of the last generation is what the device holds.
mm[:] = fill(0x7e)
mm.flush()
mm.close()
os.close(fd)
print("part3 stored")
PY

if [ "$RC" -ne 0 ]; then
    fail "mmap coherency: the run failed (rc $RC)"
    ct_exit
fi
pass "a mapping and read(2)/write(2) agree both ways, and a concurrent reader only ever saw stored bytes"

# msync durability: the stored generation must read back after the mount
# is dropped and taken again.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
if [ "$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print("ok" if d==bytes([0x7e])*len(d) and len(d)>0 else "bad")' "$MNT/cohere")" = ok ]; then
    pass "msync(MS_SYNC) is durable: the last store reads back after a remount"
else
    fail "msync(MS_SYNC) is not durable: the stored bytes did not survive a remount"
fi
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')" || pass "fsck is clean"
ct_exit
