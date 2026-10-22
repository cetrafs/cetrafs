#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file past ~343 extents spills into a depth-2 extent tree (format v2)
#
# v2 widened the extent length field (one extent -> up to 8 TiB) AND added
# a second tree level: inode root -> interior index blocks -> leaf blocks
# -> extents. Depth 1 caps a file at 4 + CETRAFS_EXT_BLOCK_MAX_LEAVES
# extents (~343); the 344th forces depth 2, raising the fragmentation
# ceiling to ~344k extents so extent-count exhaustion stops being
# reachable for a long-lived VM image.
#
# This builds a genuinely depth-2 file -- 400 NON-merging extents, one
# isolated block every other block so the run-aware allocator cannot fold
# them -- and exercises the whole lifecycle through it: full readback,
# an interior hole punch (which flattens->rebuilds the tree), a truncate
# that collapses depth 2 back down, and unlink that must free every data
# AND every meta (leaf + interior) block.
#
# DISCRIMINATION: on the pre-v2 code a file could not exceed one external
# leaf, so the 344th extent returned -ENOSPC and the write below would
# fail outright -- the "400 extents created and read back" assertions are
# what a regression to depth-1-only breaks. The shape assertion
# (depth==2) is the direct structural proof, built from the entry count,
# not inferred from timing or side effects.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# Needs a DENSE, many-extent file to reach depth 2. Speculative run
# allocation makes a sequential write contiguous, so it collapses to a
# couple of extents and the tree never spills -- the suite asserts that
# precondition rather than passing vacuously, which is how this showed
# up. Allocate one block at a time here.
ct_param_set alloc_run_blocks 0
IPOKE="$(ct_helper inode_block_poke)"

# A device big enough to hold 400 strided blocks plus metadata.
DEV="$(ct_dev 2048 d2)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt d2)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

N=400

log "building a $N-extent file (one isolated block every other block)"
python3 - "$MNT/frag" "$N" <<'PY'
import os, sys
p, n = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
for i in range(n):
    os.pwrite(fd, bytes([i & 0xff]) * 4096, i * 2 * 4096)
os.fsync(fd)
os.close(fd)
PY
sync

INO="$(stat -c %i "$MNT/frag")"
# The file must still be mounted-and-readable; read depth off the device
# via the backing file (poke reads raw, consistent with the other suites).
ct_umount "$MNT"
SHAPE="$("$IPOKE" "$IMG" extents "$INO" 2>/dev/null | head -1)"
case "$SHAPE" in
depth=2*) pass "the $N-extent file spilled to a depth-2 tree ($SHAPE)" ;;
*) fail "expected depth 2, got: $SHAPE -- the spill was not exercised" ;;
esac
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "full readback: every data block correct, every interior hole zero"
python3 - "$MNT/frag" "$N" <<'PY'
import os, sys
p, n = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_RDONLY)
for i in range(n):
    assert os.pread(fd, 4096, i * 2 * 4096) == bytes([i & 0xff]) * 4096, ("data", i)
    if i < n - 1:
        assert os.pread(fd, 4096, (i * 2 + 1) * 4096) == b'\0' * 4096, ("hole", i)
os.close(fd)
print("OK")
PY
[ $? -eq 0 ] && pass "all $N data blocks and interior holes read back correctly" ||
    fail "depth-2 readback mismatch"

log "fiemap reports the depth-2 map (flatten accessor), ascending and complete"
# fiemap and SEEK read through cetrafs_inode_extents_get()'s depth-2
# flatten path, which the raw readback above does not exercise.
python3 - "$MNT/frag" "$N" <<'PY'
import os, sys, struct, fcntl, array
p, n = sys.argv[1], int(sys.argv[2])
FS_IOC_FIEMAP = 0xC020660B
fd = os.open(p, os.O_RDONLY)
count = 2048
buf = array.array('B', struct.pack('<QQIIII', 0, 1 << 62, 0, 0, count, 0) + b'\0' * (56 * count))
fcntl.ioctl(fd, FS_IOC_FIEMAP, buf, True)
mapped = struct.unpack_from('<I', buf, 20)[0]
prev = -1
total = 0
for i in range(mapped):
    logical, phys, length, _r1, _r2, flags = struct.unpack_from('<QQQQQI', buf, 32 + i * 56)
    assert logical > prev, ("not ascending", logical, prev)
    prev = logical
    total += length
os.close(fd)
# n isolated 1-block data extents -> n mapped extents, n blocks of data
assert mapped == n, ("extent count", mapped, n)
assert total == n * 4096, ("data bytes", total)
print("OK")
PY
[ $? -eq 0 ] && pass "fiemap: $N extents, ascending, covering exactly the data" ||
    fail "fiemap of the depth-2 file is wrong"

log "punch a hole across the tree, data outside it intact"
python3 - "$MNT/frag" <<'PY'
import os, sys, ctypes
p = sys.argv[1]
fd = os.open(p, os.O_RDWR)
libc = ctypes.CDLL("libc.so.6", use_errno=True)
# FALLOC_FL_KEEP_SIZE|PUNCH_HOLE = 0x03; punch written offsets 200..220 (blocks 100..109)
r = libc.fallocate(fd, 0x03, ctypes.c_long(200 * 4096), ctypes.c_long(20 * 4096))
assert r == 0, ("fallocate", ctypes.get_errno())
assert all(os.pread(fd, 4096, (200 + k) * 4096) == b'\0' * 4096 for k in range(20)), "punched not zero"
assert os.pread(fd, 4096, 198 * 4096) == bytes([99 & 0xff]) * 4096, "pre-punch corrupted"
assert os.pread(fd, 4096, 222 * 4096) == bytes([111 & 0xff]) * 4096, "post-punch corrupted"
os.close(fd)
print("OK")
PY
[ $? -eq 0 ] && pass "punch across the depth-2 tree: hole reads zero, neighbours intact" ||
    fail "depth-2 punch wrong"

log "truncate collapses the tree back down, surviving data correct"
truncate -s "$((100 * 4096))" "$MNT/frag"
sync
python3 - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
assert os.fstat(fd).st_size == 100 * 4096
for i in range(50):
    assert os.pread(fd, 4096, i * 2 * 4096) == bytes([i & 0xff]) * 4096, ("data", i)
os.close(fd)
print("OK")
PY
[ $? -eq 0 ] && pass "after truncate the kept data is intact" || fail "truncate corrupted surviving data"
TINO="$(stat -c %i "$MNT/frag")"
ct_umount "$MNT"
TSHAPE="$("$IPOKE" "$IMG" extents "$TINO" 2>/dev/null | head -1)"
case "$TSHAPE" in
depth=0* | depth=1*) pass "truncate collapsed the tree ($TSHAPE)" ;;
*) fail "truncate left the tree at $TSHAPE" ;;
esac
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after truncate" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -iE 'err|warn' | head -3)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "unlink of a depth-2 file frees every data AND meta block"
FREE0="$(stat -f -c %f "$MNT")"
python3 - "$MNT/frag2" "$N" <<'PY'
import os, sys
p, n = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
for i in range(n):
    os.pwrite(fd, b'x' * 4096, i * 2 * 4096)
os.fsync(fd)
os.close(fd)
PY
sync
rm "$MNT/frag2"
sync
FREE1="$(stat -f -c %f "$MNT")"
[ "$FREE0" = "$FREE1" ] && pass "create+unlink of a depth-2 file leaked nothing ($FREE0 free)" ||
    fail "depth-2 unlink leaked $((FREE0 - FREE1)) blocks ($FREE0 -> $FREE1)"

log "defrag collapses a DENSE depth-2 file back to one extent"
# defrag only touches DENSE files (logically contiguous, scattered
# physically). Build one by interleaving two files block-by-block so A's
# 400 blocks are physically every-other but logically 0..399 -- depth 2,
# dense. (require_module left auto_defrag OFF, so it is not healed
# in-flight; this exercises the manual collapse deterministically.)
python3 - "$MNT/densA" "$MNT/densB" "$N" <<'PY'
import os, sys
pa, pb, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
a = os.open(pa, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
b = os.open(pb, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
for i in range(n):
    os.pwrite(a, bytes([i & 0xff]) * 4096, i * 4096)
    os.pwrite(b, b'B' * 4096, i * 4096)
os.fsync(a); os.fsync(b); os.close(b); os.close(a)
PY
sync
DINO="$(stat -c %i "$MNT/densA")"
ct_umount "$MNT"
DSHAPE="$("$IPOKE" "$IMG" extents "$DINO" 2>/dev/null | head -1)"
case "$DSHAPE" in
depth=2*) pass "the dense file is depth 2 before defrag ($DSHAPE)" ;;
*) fail "dense file is not depth 2: $DSHAPE -- defrag test would prove nothing" ;;
esac
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
DOUT="$("$ROOT/userspace/defrag.cetra" "$MNT/densA" 2>&1)" &&
    pass "defrag of a depth-2 file succeeded ($DOUT)" || fail "defrag failed: $DOUT"
# data still correct after the relocation
python3 - "$MNT/densA" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
for i in range(int(sys.argv[2])):
    assert os.pread(fd, 4096, i * 4096) == bytes([i & 0xff]) * 4096, ("data", i)
os.close(fd)
print("OK")
PY
[ $? -eq 0 ] && pass "data is byte-identical after the collapse" || fail "defrag corrupted data"
ct_umount "$MNT"
CSHAPE="$("$IPOKE" "$IMG" extents "$DINO" 2>/dev/null)"
case "$CSHAPE" in
depth=0*) pass "the tree collapsed to a single extent ($CSHAPE)" ;;
*) fail "defrag did not collapse the tree: $CSHAPE" ;;
esac
# i_blocks must drop to exactly the data blocks -- the freed meta
# (interiors + leaves) must leave the inode's block count, which the
# in-core inode update in cetrafs_defrag_inode() is responsible for
# (a stale i_blocks would be written back over the record at close).
DB="$(echo "$CSHAPE" | grep -oP 'blocks=\K[0-9]+')"
[ "$DB" = "$((N * 8))" ] && pass "i_blocks is exactly the $N data blocks ($DB sectors), no meta leaked into it" ||
    fail "i_blocks is $DB, expected $((N * 8)) -- freed meta left in the count"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean after defrag" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -iE 'err|warn' | head -3)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean at end" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -iE 'err|warn' | head -3)"
ct_exit
