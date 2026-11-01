#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an mmap store and an O_DIRECT write may allocate in the same file at once
#
# The sibling of mmap_vs_write_alloc.sh. invalidate_lock, taken
# exclusively, is what serialises extent-tree mutation between a page
# fault (which can take nothing else) and every other allocator. A
# buffered write takes it in cetrafs_write_begin(). An O_DIRECT write
# did not: blockdev_direct_IO() called cetrafs_get_block(create=1) under
# i_rwsem alone, so a fault allocating in the same file at the same
# moment started from the same record, and one of the two appends was
# dropped -- the file loses that data and the volume the block.
#
# The comments around invalidate_lock called it "the one thing
# serialising extent-tree mutation"; the O_DIRECT path was the one
# mutator it did not cover.
#
# Two faulting processes filling holes inside the file and one O_DIRECT
# writer appending past its end, all allocating in the same tree, five
# rounds (as the sibling suite measured, one round of a lock race is not
# evidence). Appending, because blockdev_direct_IO() runs with
# DIO_SKIP_HOLES: a direct write into a hole inside i_size falls back to
# the buffered path and never allocates through get_block here.
#
# DISCRIMINATION (measured on the unfixed code): blocks written through
# one path are gone, and fsck reports the same number leaked.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 mmapdio)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmapdio)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

RC=0
python3 - "$MNT" <<'PY' || RC=$?
import mmap, os, sys

mnt = sys.argv[1]
N = 512                                   # blocks, all of them holes to start

buf = mmap.mmap(-1, 4096)                 # page-aligned: what O_DIRECT needs
buf.write(b'D' * 4096)

worst = 0
for rnd in range(5):
    path = "%s/race%d" % (mnt, rnd)
    f = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    os.ftruncate(f, N * 4096)
    m = mmap.mmap(f, N * 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    d = os.open(path, os.O_RDWR | os.O_DIRECT)

    kids = []
    for half in (0, 1):
        pid = os.fork()
        if pid == 0:
            for b in range(4 * half, N, 8):       # disjoint blocks, same tree
                m[b * 4096] = 0xEE
            os._exit(0)
        kids.append(pid)
    # O_DIRECT at the same time, APPENDING past EOF: blockdev_direct_IO
    # runs with DIO_SKIP_HOLES, so a direct write into a hole inside
    # i_size falls back to the buffered path (which takes the lock) and
    # never reaches the race. Extending writes are what allocate here.
    for b in range(N, N + N // 2):
        os.pwritev(d, [buf], b * 4096)
    for pid in kids:
        os.waitpid(pid, 0)

    m.flush()
    m.close()
    os.fsync(f)
    os.close(d)
    os.posix_fadvise(f, 0, N * 4096, os.POSIX_FADV_DONTNEED)
    lost_d = [b for b in range(N, N + N // 2) if os.pread(f, 4096, b * 4096) != b'D' * 4096]
    marked = sorted(set(list(range(0, N, 8)) + list(range(4, N, 8))))
    lost_m = [b for b in marked if os.pread(f, 1, b * 4096) != b'\xee']
    os.close(f)
    print("round %d: O_DIRECT blocks lost %d %s, mmap blocks lost %d %s"
          % (rnd, len(lost_d), lost_d[:3], len(lost_m), lost_m[:3]))
    worst = max(worst, len(lost_d) + len(lost_m))

sys.stdout.flush()
sys.exit(1 if worst else 0)
PY

[ "$RC" = 0 ] &&
    pass "both writers' blocks survived: O_DIRECT and fault allocation do not race" ||
    fail "blocks written through one path are gone -- an O_DIRECT append and a fault append started from the same record"

# The lock is taken around each allocating get_block call, never across
# the whole direct write: the DIO code faults the user's buffer in
# between calls, and when that buffer is a mapping of the SAME file the
# fault takes invalidate_lock itself. Held across it, this hangs.
# NOT negative-controlled: the failure is a task in D state on an rwsem,
# which no signal can kill and which pins the module until a reboot, so
# the timeout bounds a slow path, not that one: a regression here shows
# up as a suite that never returns. (filemap_fault takes the lock shared for a folio not in the
# cache, hence the DONTNEED below.)
SELF=0
timeout 60 python3 - "$MNT/self" <<'PY' || SELF=$?
import mmap, os, sys
p = sys.argv[1]
f = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(f, b'S' * 65536, 0)               # the source, allocated
os.fsync(f)
m = mmap.mmap(f, 65536, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
os.posix_fadvise(f, 0, 65536, os.POSIX_FADV_DONTNEED)  # so the pin faults
d = os.open(p, os.O_RDWR | os.O_DIRECT)
n = os.pwritev(d, [memoryview(m)], 1 << 20)  # appends: allocates
os.close(d)
ok = n == 65536 and os.pread(f, 65536, 1 << 20) == b'S' * 65536
m.close()
os.close(f)
sys.exit(0 if ok else 1)
PY
case "$SELF" in
0) pass "an O_DIRECT append sourced from a mapping of the same file completes with its data" ;;
124) fail "an O_DIRECT append sourced from a mapping of the same file HUNG" ;;
*) fail "an O_DIRECT append sourced from a mapping of the same file failed (rc=$SELF)" ;;
esac

ct_umount "$MNT"
rc=0
FSCK="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "leaked" <<<"$FSCK"; then
    pass "fsck clean -- nothing leaked"
else
    fail "fsck rc=$rc: $(grep -E 'ERR|leaked' <<<"$FSCK" | head -2)"
fi

ct_exit
