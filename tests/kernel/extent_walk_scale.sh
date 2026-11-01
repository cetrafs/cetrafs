#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SEEK_HOLE and fiemap stay linear on a file with tens of thousands of extents
#
# The extent array is unsorted (appends merge only with the last entry),
# and both walks found "the next extent" with a fresh scan of the whole
# array per step: O(n^2). A depth-2 tree holds ~258k extents -- a
# fragmented VM image -- and one lseek(SEEK_HOLE) then ran for tens of
# seconds under inode_lock_shared with no signal check: the file's
# writers stalled behind it and nothing could kill it. fiemap had the
# same shape (its comment called it "O(n^2) on at most 343 entries").
#
# The file is written at DESCENDING offsets, so the array is in reverse
# logical order: the worst case for the old scans, and an ordinary one
# for a guest filling a disk backwards.
#
# DISCRIMINATION (measured on the unfixed code, 40k extents): filefrag
# 69.8 s (fixed: 1.2 s) and SEEK_HOLE 356 ms (fixed: 6 ms). The old
# SEEK_HOLE grows as n^2: ~15 s at the ~258k extents a depth-2 tree
# holds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "filefrag (e2fsprogs) not installed"; ct_exit; }
N=40000

DEV="$(ct_dev 600 extscale)"
MNT="$(ct_mnt extscale)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

python3 - "$MNT/f" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
blk = b'D' * 4096
for i in range(int(sys.argv[2]) - 1, -1, -1):
    os.pwrite(fd, blk, i * 4096)
os.fsync(fd)
os.close(fd)
PY
sync
echo 3 >/proc/sys/vm/drop_caches

t0=$(date +%s%N)
out="$(filefrag "$MNT/f")"
t1=$(date +%s%N)
ext="$(sed -n 's/.*: \([0-9]*\) extents\? found/\1/p' <<<"$out")"
[ "${ext:-0}" -ge $((N / 2)) ] && pass "setup: the file has $ext extents" ||
    { fail "setup: only '${ext:-?}' extents -- the layout did not fragment ($out)"; ct_exit; }
ms=$(((t1 - t0) / 1000000))
log "filefrag over $ext extents: ${ms} ms"
[ "$ms" -lt 3000 ] && pass "fiemap is linear (${ms} ms)" || fail "fiemap took ${ms} ms over $ext extents -- quadratic"

read -r hole ms < <(python3 - "$MNT/f" <<'PY'
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
t = time.monotonic()
h = os.lseek(fd, 0, os.SEEK_HOLE)
print(h, int((time.monotonic() - t) * 1000))
PY
)
[ "$hole" = $((N * 4096)) ] && pass "SEEK_HOLE answers EOF on the dense file" ||
    fail "SEEK_HOLE answered $hole, expected $((N * 4096))"
log "SEEK_HOLE over $ext extents: ${ms} ms"
[ "$ms" -lt 150 ] && pass "SEEK_HOLE is linear (${ms} ms)" || fail "SEEK_HOLE took ${ms} ms -- quadratic"

# Correctness with real holes, against an independent model: punch every
# 7th block, then walk SEEK_DATA/SEEK_HOLE and compare with the map.
res="$(python3 - "$MNT/f" "$N" <<'PY'
import fcntl, os, sys, ctypes
fd = os.open(sys.argv[1], os.O_RDWR)
n = int(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
PUNCH = 0x01 | 0x02  # FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
holes = set(range(0, n, 7))
for b in holes:
    if libc.fallocate(fd, PUNCH, ctypes.c_long(b * 4096), ctypes.c_long(4096)) != 0:
        print("punch failed", ctypes.get_errno()); sys.exit(1)
want, got, off = [], [], 0
b = 0
while b < n:  # model: runs of data
    if b in holes:
        b += 1; continue
    s = b
    while b < n and b not in holes:
        b += 1
    want.append((s * 4096, b * 4096))
size = n * 4096
while off < size:
    try:
        d = os.lseek(fd, off, os.SEEK_DATA)
    except OSError:
        break
    h = os.lseek(fd, d, os.SEEK_HOLE)
    got.append((d, h))
    off = h
print("ok" if got == want else "MISMATCH %s vs %s" % (got[:3], want[:3]))
PY
)"
[ "$res" = ok ] && pass "SEEK_DATA/SEEK_HOLE match the model across $((N / 7)) punched holes" ||
    fail "SEEK walk disagrees with the model: $res"

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -2)"
ct_exit
