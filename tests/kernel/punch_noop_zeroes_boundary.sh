#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch that frees no whole block still zeroes its partial boundary blocks
#
# A punch whose whole blocks are all holes already changes nothing in
# the extent map, and publishes nothing -- but the parts of the
# boundary blocks inside the range still hold data the caller asked to
# turn into zeros. When the boundary zeroing moved after the record
# publish, it moved after that no-op return too, and such a punch left
# the data in place: churn_oracle found a hole reading back an older
# write ("HOLE HOLDS DATA").
#
#  A. tail: [4096, +8192) on a 9101-byte file whose block 1 is a hole --
#     the 909 bytes of block 2 below EOF must read zero;
#  B. head: [100, +8092) where block 1 is a hole -- bytes [100, 4096)
#     of block 0 must read zero;
#  C. control: the bytes outside the range are untouched.
#
# DISCRIMINATION (measured on the unfixed code): A and B read the old
# data, before and after a remount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 pnz)"
MNT="$(ct_mnt pnz)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

punch() { # <file> <offset> <len>
    python3 -I - "$1" "$2" "$3" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR)
r = libc.fallocate(fd, 3, ctypes.c_long(int(sys.argv[2])), ctypes.c_long(int(sys.argv[3])))  # PUNCH_HOLE|KEEP_SIZE
os.close(fd)
sys.exit(0 if r == 0 else 1)
PY
}

# <file> <size>: three blocks of 'A', cut to <size>, block 1 punched out
# and the whole thing on the device -- so the second punch below has no
# whole block left to free.
mkfile() {
    python3 -I - "$1" "$2" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
os.pwrite(fd, b"A" * 12288, 0)
os.ftruncate(fd, int(sys.argv[2]))
os.fsync(fd)
os.close(fd)
PY
    punch "$1" 4096 4096 || { fail "setup: could not punch block 1 of $1"; ct_exit; }
    sync
}

# <file> <offset> <len>: are those bytes all zero?
zeros() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
b = os.pread(fd, int(sys.argv[3]), int(sys.argv[2]))
os.close(fd)
sys.exit(0 if len(b) == int(sys.argv[3]) and not any(b) else 1)
PY
}
# <file> <offset> <len>: are those bytes all 'A'?
as_() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
b = os.pread(fd, int(sys.argv[3]), int(sys.argv[2]))
os.close(fd)
sys.exit(0 if len(b) == int(sys.argv[3]) and b == b"A" * len(b) else 1)
PY
}

mkfile "$MNT/tail" 9101
mkfile "$MNT/head" 12288
zeros "$MNT/tail" 4096 4096 && zeros "$MNT/head" 4096 4096 && as_ "$MNT/tail" 8192 909 && as_ "$MNT/head" 0 4096 ||
    { fail "setup: the files do not hold A, a hole, A"; ct_exit; }
pass "setup: block 1 of both files is a hole; the blocks around it hold data"

punch "$MNT/tail" 4096 8192 || fail "A: the punch failed"
punch "$MNT/head" 100 8092 || fail "B: the punch failed"

check() { # <when>
    zeros "$MNT/tail" 8192 909 && pass "A ($1): the tail of the range reads zero" ||
        fail "A ($1): the 909 bytes below EOF inside the punched range still hold data"
    zeros "$MNT/head" 100 3996 && pass "B ($1): the head of the range reads zero" ||
        fail "B ($1): bytes [100, 4096) inside the punched range still hold data"
    as_ "$MNT/head" 0 100 && as_ "$MNT/head" 8192 4096 && pass "C ($1): the bytes outside both ranges are intact" ||
        fail "C ($1): a punch changed bytes outside its range"
}
check "cached"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
check "after a remount"
ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
ct_exit
