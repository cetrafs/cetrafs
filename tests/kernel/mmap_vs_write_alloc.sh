#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an mmap store and a write(2) may allocate in the same file at once
#
# Allocating a block means reading the inode record, appending an extent
# and staging the result. write(2), truncate, punch and fallocate all do
# that under inode_lock, so they serialise against each other.
#
# A page fault does not, and cannot: it already holds mmap_lock, and
# i_rwsem is taken before mmap_lock everywhere else, so taking it in a
# fault inverts the order. Until .page_mkwrite existed the fault path
# allocated in WRITEBACK, which happened to be after the writer was done
# -- allocating at fault time (which is what makes -ENOSPC reportable,
# see mmap_enospc_sigbus.sh) put the two in the same instant.
#
# Two appends from the same starting record: one of them wins and the
# other's extent is dropped. Its block stays marked in use, so the file
# loses data AND the volume loses the block.
#
# invalidate_lock is the lock a fault CAN take; cetrafs_page_mkwrite()
# and cetrafs_write_begin() take it exclusively, which is what makes
# extent-tree mutation serialised again.
#
# Discrimination: take it shared in cetrafs_page_mkwrite(), or drop it
# from cetrafs_write_begin(), and a single round loses tens of blocks on
# both sides and fsck reports the same number leaked.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 mmapalloc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmapalloc)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Five rounds: this is a race. With the fault path taking the lock
# shared, two of three rounds came back dirty -- at three rounds that
# is a 4% chance of a false green, at five it is under one in 200.
RC=0
python3 - "$MNT" <<'PY' || RC=$?
import mmap, os, sys

mnt = sys.argv[1]
N = 512                                   # blocks, all of them holes to start

worst = 0
for rnd in range(5):
    path = "%s/race%d" % (mnt, rnd)
    f = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    os.ftruncate(f, N * 4096)
    m = mmap.mmap(f, N * 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)

    # TWO faulting processes, not one: a single one would never race
    # another fault, and the suite would pass with the fault path taking
    # invalidate_lock SHARED -- which does not serialise two appends
    # against each other, only against the writer.
    kids = []
    for half in (0, 1):
        pid = os.fork()
        if pid == 0:
            for b in range(4 * half, N, 8):       # disjoint blocks, same tree
                m[b * 4096] = 0xEE
            os._exit(0)
        kids.append(pid)
    for b in range(1, N, 2):              # write(2) at the same time: odd blocks
        os.pwrite(f, b'W' * 4096, b * 4096)
    for pid in kids:
        os.waitpid(pid, 0)

    m.flush()
    m.close()
    os.fsync(f)
    os.posix_fadvise(f, 0, N * 4096, os.POSIX_FADV_DONTNEED)
    lost_w = [b for b in range(1, N, 2) if os.pread(f, 4096, b * 4096) != b'W' * 4096]
    marked = sorted(set(list(range(0, N, 8)) + list(range(4, N, 8))))
    lost_m = [b for b in marked if os.pread(f, 1, b * 4096) != b'\xee']
    os.close(f)
    print("round %d: write(2) blocks lost %d %s, mmap blocks lost %d %s"
          % (rnd, len(lost_w), lost_w[:3], len(lost_m), lost_m[:3]))
    worst = max(worst, len(lost_w) + len(lost_m))

sys.stdout.flush()
os._exit(1 if worst else 0)
PY

[ "$RC" = 0 ] &&
    pass "both writers' blocks survived: the two allocation paths do not race" ||
    fail "blocks written through one path are gone -- two appends started from the same record and one was dropped"

ct_umount "$MNT"
FSCK="$(ct_fsck "$DEV" 2>&1)" || fail "fsck found faults: $(echo "$FSCK" | grep -i err | head -2)"
echo "$FSCK" | grep -q "leaked" &&
    fail "the dropped extents leaked their blocks: $(echo "$FSCK" | grep leaked | head -1)" ||
    pass "fsck clean -- nothing leaked"

ct_exit
