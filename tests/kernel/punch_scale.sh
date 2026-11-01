#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# punching a large range of a heavily fragmented file is linear, not one memmove per dropped extent
#
# The punch edits the FLATTENED extent array -- up to ~258k entries at
# depth 2 -- and removed each fully-covered entry with a memmove of the
# whole rest of the array: O(dropped x n), under the exclusive
# invalidate_lock, with no reschedule. A guest's TRIM of a large range
# of a fragmented VM image is exactly that punch.
#
# The file is written at descending offsets, so the punched upper half
# sits at the FRONT of the array: every dropped entry moved everything
# after it.
#
# DISCRIMINATION (measured on the unfixed code, 40k extents): 339 ms
# against 12 ms fixed. Quadratic: ~14 s at the ~258k a depth-2 tree
# holds, all of it under the exclusive invalidate_lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
N=40000

DEV="$(ct_dev 600 punchscale)"
MNT="$(ct_mnt punchscale)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

python3 - "$MNT/f" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
for i in range(int(sys.argv[2]) - 1, -1, -1):
    os.pwrite(fd, i.to_bytes(4, 'little') * 1024, i * 4096)
os.fsync(fd)
os.close(fd)
PY
sync
ext="$(filefrag "$MNT/f" 2>/dev/null | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p')"
[ "${ext:-0}" -ge $((N / 2)) ] && pass "setup: the file has $ext extents" ||
    { fail "setup: only '${ext:-?}' extents"; ct_exit; }

read -r rc ms < <(python3 - "$MNT/f" "$N" <<'PY'
import ctypes, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
n = int(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
t = time.monotonic()
r = libc.fallocate(fd, 0x01 | 0x02, ctypes.c_long(n // 2 * 4096), ctypes.c_long(n // 2 * 4096))
print(r if r == 0 else -ctypes.get_errno(), int((time.monotonic() - t) * 1000))
PY
)
[ "$rc" = 0 ] && pass "setup: the punch of $((N / 2)) extents succeeded" || { fail "punch failed: $rc"; ct_exit; }
log "punching $((N / 2)) of $ext extents: ${ms} ms"
[ "$ms" -lt 100 ] && pass "the punch is linear (${ms} ms)" || fail "the punch took ${ms} ms -- quadratic in the extent count"

echo 3 >/proc/sys/vm/drop_caches
res="$(python3 - "$MNT/f" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
n = int(sys.argv[2])
for i in range(n):
    d = os.pread(fd, 4096, i * 4096)
    want = i.to_bytes(4, 'little') * 1024 if i < n // 2 else b'\0' * 4096
    if d != want:
        print("block %d wrong" % i); sys.exit(0)
print("ok")
PY
)"
[ "$res" = ok ] && pass "every kept block reads its own content and every punched one reads zeros" ||
    fail "content after the punch: $res"

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean (nothing leaked, nothing double-freed)" ||
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -2)"
ct_exit
