#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ct-timeout: 900
# large logical offsets: writes, holes, SEEK, fiemap, punch and truncate at the format's boundaries
#
# A file's logical block is 48 bits (v0x000A, M-42) and an extent covers
# at most 2^31 blocks (CETRAFS_EXT_LEN_MASK, 8 TiB); a file is addressable
# to 2^48 blocks. The arithmetic that crosses powers of two is where
# aliasing hides: when the block was 32 bits, max_file_size.sh found a
# write at 16 TiB read back at offset 0. 2^31 and 2^32 stay the edges
# swept here -- 2^32 is where a leftover 32-bit carry would wrap -- and
# 4b puts one extent across 2^32. The large-offset suites so far each probe ONE offset;
# this sweeps the boundaries together, and through every path that
# reads the same map -- write, read, SEEK_DATA/SEEK_HOLE, FIEMAP, punch,
# truncate and the byte-level i_size edges.
#
# Built on a nominally 17 TiB device (ct_huge_dev: device-mapper, no
# 16 TiB backing file), so only what is written costs space.
#
# Blocks used: B1 = 2^31-2, B2 = 2^31 (the first block past 8 TiB),
# B3 = 2^32-3, B4 = 2^32-1 (the last addressable block). Each carries its
# own pattern; the blocks between them are holes, and their neighbours
# must read as holes too -- an alias would put a pattern there.
#
# DISCRIMINATION: the last section aliases a leaf extent onto logical
# block 0 (leaf_poke setblock), offline, and requires the read-back check
# to see it. That is the one state the sweep exists to catch, and the
# control proves the check does. The ceiling injection in the notes at
# docs/internal/TEST-COVERAGE-GAPS.md section 8 is the other proof.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v python3 >/dev/null || { skip "python3 not found"; ct_exit; }
LPOKE="$(ct_helper leaf_poke)"

DEV="$(ct_huge_dev 17 lofs)"
if [ -z "$DEV" ]; then
    skip "device-mapper is unavailable; a volume past 16 TiB cannot be built here"
    ct_exit
fi
MNT="$(ct_mnt lofs)"
ct_track mnt "$MNT"

# A 128 GiB Block Group keeps mkfs's bitmap writes small on this size.
ct_mkfs "$DEV" -b 131072 -z 8 -J 0 -N 1024 -M 4 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

B1=$((2 ** 31 - 2))
B2=$((2 ** 31))
B3=$((2 ** 32 - 3))
B4=$((2 ** 32 - 1))
MAXB=$((2 ** 48))
MAXBYTES=$((MAXB * 4096))

# Five low blocks come first. Four extents fill a file's inline array, so
# with them the file's extent map spills into a depth-1 leaf, and the
# boundary extents below live in that leaf -- where the u32 end arithmetic
# (file.c, the leaf range) is, not in the inline slots.
LOW0=100
LOW="$LOW0 200 300 400 500"

# ---- 1. writes at the boundaries read back exactly, with no alias
log "writing one block at each boundary, and checking holes around them"
OUT="$(python3 -I - "$MNT/big" $LOW "$B1" "$B2" "$B3" "$B4" <<'PY'
import os, sys
path = sys.argv[1]
blocks = [int(x) for x in sys.argv[2:]]
def pat(b):
    # Per block, and two bytes wide, so no two blocks share a pattern.
    return bytes([1 + b % 251, 1 + (b >> 8) % 251]) * 2048
pats = [pat(b) for b in blocks]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
for b, p in zip(blocks, pats):
    os.pwrite(fd, p, b * 4096)
os.fsync(fd)
errs = []
for b, p in zip(blocks, pats):
    if os.pread(fd, 4096, b * 4096) != p:
        errs.append("block %d reads back wrong" % b)
    for nb in (b - 1, b + 1):
        if 0 <= nb <= blocks[-1] and nb not in blocks and os.pread(fd, 4096, nb * 4096) != b"\0" * 4096:
            errs.append("hole block %d (next to %d) is not zero" % (nb, b))
if os.pread(fd, 4096, 0) != b"\0" * 4096:
    errs.append("block 0 is not a hole")
size = os.fstat(fd).st_size
if size != (blocks[-1] + 1) * 4096:
    errs.append("i_size %d, expected %d" % (size, (blocks[-1] + 1) * 4096))
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
if [ "$OUT" = OK ]; then
    pass "1: each boundary block reads back its own pattern, holes around it are zero, and i_size is exact"
else
    fail "1: boundary writes: $(printf '%s' "$OUT" | tr '\n' ';')"
fi

# ---- 2. SEEK_DATA / SEEK_HOLE and FIEMAP agree with what was written
log "SEEK_DATA/SEEK_HOLE and FIEMAP at the boundaries"
OUT="$(python3 -I - "$MNT/big" "$LOW0" "$B1" "$B2" "$B3" "$B4" <<'PY'
import errno, fcntl, os, struct, sys
path = sys.argv[1]
low0, b1, b2, b3, b4 = [int(x) for x in sys.argv[2:7]]
fd = os.open(path, os.O_RDONLY)
errs = []
def seek(off, whence):
    try:
        return os.lseek(fd, off, whence)
    except OSError as e:
        return -e.errno
D, H = os.SEEK_DATA, os.SEEK_HOLE
checks = [
    ("SEEK_DATA from 0", seek(0, D), low0 * 4096),
    ("SEEK_DATA past the low block", seek((low0 + 1) * 4096, D), 200 * 4096),
    ("SEEK_DATA past B1", seek((b1 + 1) * 4096, D), b2 * 4096),
    ("SEEK_DATA past B2", seek((b2 + 1) * 4096, D), b3 * 4096),
    ("SEEK_DATA past B3", seek((b3 + 1) * 4096, D), b4 * 4096),
    ("SEEK_HOLE at B1", seek(b1 * 4096, H), (b1 + 1) * 4096),
    ("SEEK_HOLE at B4", seek(b4 * 4096, H), (b4 + 1) * 4096),
    ("SEEK_DATA past B4", seek((b4 + 1) * 4096, D), -errno.ENXIO),
]
for name, got, want in checks:
    if got != want:
        errs.append("%s: %d, expected %d" % (name, got, want))
# FIEMAP over the whole file: every written block is mapped at its own
# logical offset, and the holes next to them are not.
FS_IOC_FIEMAP = 0xC020660B
N = 64
buf = bytearray(32 + 56 * N)
struct.pack_into("=QQLLLL", buf, 0, 0, (1 << 64) - 1, 0, 0, N, 0)
fcntl.ioctl(fd, FS_IOC_FIEMAP, buf)
mapped = struct.unpack_from("=L", buf, 24)[0]
exts = []
for i in range(mapped):
    logical, phys, length = struct.unpack_from("=QQQ", buf, 32 + 56 * i)
    exts.append((logical, phys, length))
if not mapped:
    errs.append("FIEMAP maps nothing")
for b in (low0, b1, b2, b3, b4):
    hit = [e for e in exts if e[0] <= b * 4096 < e[0] + e[2]]
    if not hit:
        errs.append("FIEMAP does not map block %d" % b)
    elif hit[0][1] == 0:
        errs.append("FIEMAP maps block %d to physical block 0" % b)
for nb in (low0 + 1, b1 - 1, b1 + 1, b3 + 1):
    if any(e[0] <= nb * 4096 < e[0] + e[2] for e in exts):
        errs.append("FIEMAP maps hole block %d" % nb)
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
if [ "$OUT" = OK ]; then
    pass "2: SEEK_DATA/SEEK_HOLE and FIEMAP report the written blocks at their own offsets"
else
    fail "2: SEEK/FIEMAP: $(printf '%s' "$OUT" | tr '\n' ';')"
fi

# ---- 3. punch and truncate across the boundaries
log "punching B2 and truncating across B3"
if fallocate --punch-hole --offset $((B2 * 4096)) --length 4096 "$MNT/big" 2>/dev/null; then
    OUT="$(python3 -I - "$MNT/big" "$B1" "$B2" "$B3" "$B4" <<'PY'
import os, sys
path = sys.argv[1]
b1, b2, b3, b4 = [int(x) for x in sys.argv[2:6]]
def pat(b):
    return bytes([1 + b % 251, 1 + (b >> 8) % 251]) * 2048
fd = os.open(path, os.O_RDONLY)
errs = []
if os.pread(fd, 4096, b2 * 4096) != b"\0" * 4096:
    errs.append("punched block %d still holds data" % b2)
if os.pread(fd, 4096, b1 * 4096) != pat(b1):
    errs.append("punch took block %d (next door)" % b1)
if os.pread(fd, 4096, b3 * 4096) != pat(b3):
    errs.append("punch took block %d (next door)" % b3)
if os.lseek(fd, (b1 + 1) * 4096, os.SEEK_DATA) != b3 * 4096:
    errs.append("SEEK_DATA after the punch does not skip to block %d" % b3)
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
    [ "$OUT" = OK ] && pass "3a: a punch at 8 TiB clears exactly its block, and SEEK_DATA skips it" ||
        fail "3a: punch at 8 TiB: $(printf '%s' "$OUT" | tr '\n' ';')"
else
    fail "3a: fallocate --punch-hole at 8 TiB failed"
fi

# Truncate down to just past B3: B4 must be gone, B3 kept.
if truncate -s $(((B3 + 1) * 4096)) "$MNT/big" 2>/dev/null; then
    truncate -s $((MAXBYTES)) "$MNT/big" 2>/dev/null || true
    OUT="$(python3 -I - "$MNT/big" "$B3" "$B4" <<'PY'
import os, sys
path = sys.argv[1]
b3, b4 = int(sys.argv[2]), int(sys.argv[3])
def pat(b):
    return bytes([1 + b % 251, 1 + (b >> 8) % 251]) * 2048
fd = os.open(path, os.O_RDONLY)
errs = []
if os.pread(fd, 4096, b3 * 4096) != pat(b3):
    errs.append("truncate lost block %d, which lies below the new size" % b3)
if os.pread(fd, 4096, b4 * 4096) != b"\0" * 4096:
    errs.append("block %d survived a truncate below it" % b4)
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
    [ "$OUT" = OK ] && pass "3b: truncating to just past B3 keeps B3 and drops B4, and re-extending reads zeros" ||
        fail "3b: truncate across B4: $(printf '%s' "$OUT" | tr '\n' ';')"
else
    fail "3b: truncate to just past B3 was refused"
fi

# ---- 4. byte-level i_size edges at the 2^60-byte ceiling
log "the byte at the ceiling, and one past it"
OUT="$(python3 -I - "$MNT/edge" "$MAXBYTES" <<'PY'
import errno, os, sys
path = sys.argv[1]
top = int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
errs = []
os.pwrite(fd, b"Z", 1234)
os.fsync(fd)
try:
    os.pwrite(fd, b"T", top - 1)
except OSError as e:
    errs.append("the last byte (offset %d) was refused: %s" % (top - 1, errno.errorcode.get(e.errno, e.errno)))
try:
    os.pwrite(fd, b"X", top)
    errs.append("a byte at the ceiling (offset %d) was accepted" % top)
except OSError as e:
    if e.errno != errno.EFBIG:
        errs.append("a byte at the ceiling refused with %s, not EFBIG" % errno.errorcode.get(e.errno, e.errno))
n = 0
try:
    n = os.pwrite(fd, b"YZ", top - 1)
except OSError as e:
    n = -e.errno
if n not in (1, -errno.EFBIG):
    errs.append("a write straddling the ceiling returned %d" % n)
if os.pread(fd, 1, top - 1) != b"Y" and n == 1:
    errs.append("the in-range byte of a straddling write did not land")
if os.pread(fd, 1, 0) != b"\0":
    errs.append("offset 0 changed: the top of the file aliased onto it")
alias = ((top - 1) // 4096 % 2 ** 32) * 4096 + 4095  # where a 32-bit carry would put it
if os.pread(fd, 1, alias) != b"\0":
    errs.append("offset %d changed: the top of the file aliased onto its 32-bit truncation" % alias)
if os.pread(fd, 1, 1234) != b"Z":
    errs.append("the byte written at 1234 was disturbed")
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
[ "$OUT" = OK ] && pass "4: the last byte is writable, the byte past it is refused with EFBIG, and nothing aliases offset 0" ||
    fail "4: i_size edges: $(printf '%s' "$OUT" | tr '\n' ';')"

# ---- 4b. one extent across 2^32
#
# Three adjacent blocks written in order merge into one extent whose
# logical start is below 2^32 and whose end is above it: the start's
# high bits, the run arithmetic and the punch split all cross there.
log "an extent straddling block 2^32: read, SEEK, punch"
OUT="$(python3 -I - "$MNT/straddle" <<'PY'
import ctypes, errno, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
SEEK_DATA, SEEK_HOLE = 3, 4
B = 2 ** 32
path = sys.argv[1]
pat = lambda b: (b"S%015d" % b) * 256
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
errs = []
for b in (B - 1, B, B + 1):
    os.pwrite(fd, pat(b), b * 4096)
os.fsync(fd)
for b in (B - 1, B, B + 1):
    if os.pread(fd, 4096, b * 4096) != pat(b):
        errs.append("block %d does not read back" % b)
for b in (B - 2, 0, 1):
    if os.pread(fd, 4096, b * 4096) != b"\0" * 4096:
        errs.append("block %d is not a hole" % b)
if os.fstat(fd).st_size != (B + 2) * 4096 or os.pread(fd, 4096, (B + 2) * 4096) != b"":
    errs.append("i_size is %d, not the end of block 2^32+1" % os.fstat(fd).st_size)
if os.lseek(fd, 0, SEEK_DATA) != (B - 1) * 4096:
    errs.append("SEEK_DATA from 0 is %d, not block 2^32-1" % os.lseek(fd, 0, SEEK_DATA))
if os.lseek(fd, (B - 1) * 4096, SEEK_HOLE) != (B + 2) * 4096:
    errs.append("SEEK_HOLE past the run is %d, not block 2^32+2" % os.lseek(fd, (B - 1) * 4096, SEEK_HOLE))
if libc.fallocate(fd, 3, B * 4096, 4096) != 0:  # PUNCH_HOLE | KEEP_SIZE
    errs.append("punching block 2^32 failed: %s" % errno.errorcode.get(ctypes.get_errno()))
os.fsync(fd)
if os.pread(fd, 4096, B * 4096) != b"\0" * 4096:
    errs.append("block 2^32 still holds data after the punch")
for b in (B - 1, B + 1):
    if os.pread(fd, 4096, b * 4096) != pat(b):
        errs.append("block %d lost its data to the punch of 2^32" % b)
if os.lseek(fd, B * 4096, SEEK_DATA) != (B + 1) * 4096:
    errs.append("SEEK_DATA from the punched block is %d, not 2^32+1" % os.lseek(fd, B * 4096, SEEK_DATA))
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
[ "$OUT" = OK ] && pass "4b: an extent across 2^32 reads back, SEEKs and punches at the right blocks" ||
    fail "4b: straddling 2^32: $(printf '%s' "$OUT" | tr '\n' ';')"

# ---- 5. control: the sweep must see an alias
#
# Offline, move a leaf extent onto logical block 0. A correct read at
# offset 0 returns zeros; the aliased one returns that extent's data.
INO="$(stat -c %i "$MNT/big")"
ct_umount "$MNT"
# The file's map is a depth-1 leaf now, so the extents are in the leaf and
# the inline slots hold its index: entry 0 of the leaf is the extent to move.
if ! "$LPOKE" "$DEV" show "$INO" 2>/dev/null | grep -q .; then
    fail "control setup: the file has no extent leaf to alias from"
    ct_exit
fi
if ! "$LPOKE" "$DEV" setblock "$INO" 0 0 >/dev/null 2>&1; then
    fail "control setup: could not move leaf entry 0 of the file onto block 0"
    ct_exit
fi
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ALIAS="$(python3 -I - "$MNT/big" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print("ALIASED" if os.pread(fd, 4096, 0) != b"\0" * 4096 else "CLEAN")
PY
)"
ct_umount "$MNT"
[ "$ALIAS" = ALIASED ] && pass "control: an extent moved onto logical block 0 is seen (offset 0 reads the 8 TiB block's data)" ||
    fail "control: the aliased extent read back as a hole -- the read check cannot see an alias"

ct_exit
