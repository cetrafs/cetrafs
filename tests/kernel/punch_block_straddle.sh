#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a hole that straddles a block boundary without covering a whole block
#
# cetrafs_fallocate()'s punch path short-circuits when no WHOLE block
# lies inside [offset, end): nothing can be freed, and the general
# boundary handling below it assumes the two boundaries are in different
# blocks. That short-circuit used to zero [offset, end) in ONE call.
#
# "Covers no whole block" is not "lies within one block", and conflating
# them was a kernel BUG reachable by any user with write access to a
# file on the mount. Punching [4095, +2) straddles a block boundary
# while covering no whole block, so the single zeroing handed
# block_write_begin() a range crossing the end of the folio it was
# given:
#
#   kernel BUG at fs/buffer.c:2020!
#     __block_write_begin_int -> block_write_begin
#     -> cetrafs_zero_range -> cetrafs_fallocate -> vfs_fallocate
#
# Zeroing goes through the ordinary write path, which is handed one
# folio at a time, so every range given to it must stay inside one
# block. The branch now splits on the boundary.
#
# Discrimination: this is the class of regression whose negative control
# does not fail an assertion, it OOPSES THE MACHINE -- so it was run by
# hand once, on a disposable VM, against the unfixed module, and the
# trace above is what it produced. In the gate the assertions below are
# what stands: a kernel that survives them and returns the right bytes
# is a kernel where the branch split correctly.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 punchstraddle)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt punchstraddle)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

MARK="$(dmesg_mark)"
RC=0
python3 - "$MNT/victim" <<'PY' || RC=$?
import ctypes, os, sys

BS = 4096
KEEP, PUNCH = 0x01, 0x02
libc = ctypes.CDLL("libc.so.6", use_errno=True)
path = sys.argv[1]

# Every shape that reaches the "covers no whole block" branch: inside one
# block, exactly up to a boundary, exactly from one, and -- the one that
# crashed -- straddling the boundary.
CASES = [
    (BS - 1, 2, "straddles the boundary by one byte each side"),
    (BS - 1, 1, "ends exactly at the boundary"),
    (BS,     1, "starts exactly at the boundary"),
    (BS - 8, 16, "straddles with a wider overlap"),
    (100,    50, "wholly inside one block"),
    (BS - 1, BS + 1, "straddles and reaches the end of the next block"),
    (3 * BS - 1, 2, "straddles a later boundary"),
]

size = 8 * BS
bad = []
for off, ln, what in CASES:
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(f, b'A' * size)
    os.fsync(f)

    r = libc.fallocate(f, PUNCH | KEEP, ctypes.c_long(off), ctypes.c_long(ln))
    if r != 0:
        bad.append("%s: fallocate(%d,%d) failed: %s"
                   % (what, off, ln, os.strerror(ctypes.get_errno())))
        os.close(f)
        continue

    # Read back through the mapping, not the page cache.
    os.posix_fadvise(f, 0, size, os.POSIX_FADV_DONTNEED)
    got = os.pread(f, size, 0)
    want = b'A' * off + b'\0' * ln + b'A' * (size - off - ln)
    if got != want:
        first = next(i for i in range(size) if got[i] != want[i])
        bad.append("%s: fallocate(%d,%d) left byte %d as %r, expected %r"
                   % (what, off, ln, first, got[first:first+1], want[first:first+1]))
    os.close(f)

for b in bad:
    print(b)
sys.stdout.flush()
os._exit(1 if bad else 0)
PY

[ "$RC" = 0 ] &&
    pass "a hole straddling a block boundary zeroes exactly itself, and the kernel survives it" ||
    fail "punching across a block boundary went wrong (see above) -- the no-whole-block branch is not splitting"

! dmesg_since "$MARK" | grep -qE 'kernel BUG|Oops|Internal error' &&
    pass "no kernel BUG in the log" ||
    fail "the kernel faulted: $(dmesg_since "$MARK" | grep -E 'kernel BUG|Oops|Internal error' | head -2)"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after the straddling punches"
pass "fsck clean"

ct_exit
