#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the fuzzers' golden image: a mkfs'd volume POPULATED through a
# real mount, so fsck's content/namespace passes and the kernel's own
# readers have real structure to parse -- directories past one block, a
# depth-1 (external extent leaf) file, symlink, hardlink, xattrs, a
# punched hole. An mkfs-only golden would leave most of both parsers
# untouched. Usage: mkgolden.sh <output-image>
set -euo pipefail
OUT="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
make -s -C "$ROOT/userspace" >/dev/null
modprobe libcrc32c 2>/dev/null || true
modprobe scsi_mod 2>/dev/null || true
if ! lsmod | grep -q '^cetrafs '; then
    make -s -C "$ROOT" mod >/dev/null
    insmod "$ROOT/kmod/cetrafs.ko" auto_defrag=0
    LOADED=1
fi
rm -f "$OUT"
truncate -s 560M "$OUT"
LOOP="$(losetup --find --show "$OUT")"
MNT="$(mktemp -d /tmp/cetrafs-golden-XXXXXX)"
cleanup() {
    umount "$MNT" 2>/dev/null || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    [ "${LOADED:-}" = "1" ] && rmmod cetrafs 2>/dev/null || true
}
trap cleanup EXIT
"$ROOT/userspace/mkfs.cetra" "$LOOP" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
mount -t cetrafs "$LOOP" "$MNT"
echo "golden file zero" >"$MNT/f0"
mkdir -p "$MNT/d1/d2/d3"
for i in $(seq 1 40); do echo "payload $i" >"$MNT/d1/file$i"; done
ln -s d1/file1 "$MNT/sym"
ln "$MNT/d1/file2" "$MNT/hard"
python3 - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
os.setxattr(m + "/f0", "user.k1", b"v1")
os.setxattr(m + "/f0", "user.k2", b"v" * 200)
# depth-1 file: >4 extents via descending writes (never merge)
fd = os.open(m + "/deep", os.O_CREAT | os.O_RDWR, 0o644)
blk = b"D" * 4096
for i in (9, 7, 5, 3, 1, 0):
    os.pwrite(fd, blk, i * 4096)
os.fsync(fd)
os.close(fd)
# a punched hole
fd = os.open(m + "/holey", os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(fd, b"H" * (64 * 4096), 0)
os.fsync(fd)
import ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
# FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE = 0x01 | 0x02
if libc.fallocate(fd, 0x03, ctypes.c_long(16 * 4096), ctypes.c_long(8 * 4096)) != 0:
    raise OSError(ctypes.get_errno(), "fallocate punch failed")
os.fsync(fd)
os.close(fd)
# frag: DENSE, in order, and physically fragmented -- the only shape the
# defrag mover acts on. It declines holes and preallocated extents, which
# is every other file here, and it judges "dense" over the extent array
# as stored, so blocks written out of order are declined too: with none
# of these the mover was unreachable from the fuzzer. Written front to
# back, closing after each block so its speculative run is given back
# and a spacer file takes the next block: 32 one-block extents.
for i in range(32):
    fd = os.open(m + "/frag", os.O_CREAT | os.O_WRONLY, 0o644)
    os.pwrite(fd, bytes([65 + i % 26]) * 4096, i * 4096)
    os.fsync(fd)
    os.close(fd)
    fd = os.open(m + "/fragspacer", os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
    os.write(fd, b"s" * 4096)
    os.fsync(fd)
    os.close(fd)
PY
umount "$MNT"

# GROWN, deliberately.
#
# Everything that only exists after a grow was unfuzzed, because every
# golden was a freshly-made volume: on one of those bg_table_next is 0,
# so the Block Group table is the contiguous run it has always been and
# fs.c's chain walk never executes a single iteration. The segment
# chain, the tail reserve and layout_gen had no representation in the
# corpus at all -- not because the fuzzer was weak, but because there
# was nothing of them in the images it was given.
#
# The grow adds a second Block Group, which is what puts a real
# cetrafs_bg_segment_t on the device for the fuzzer to mutate.
losetup -d "$LOOP"; LOOP=""
truncate -s 1300M "$OUT"
LOOP="$(losetup --find --show "$OUT")"
"$ROOT/userspace/growfs.cetra" "$LOOP" >/dev/null 2>&1 || {
    echo "growing the golden failed" >&2; exit 1; }

"$ROOT/userspace/fsck.cetra" "$LOOP" >/dev/null || { echo "golden image is not fsck-clean" >&2; exit 1; }
# And it must really have a chain, or the targets below silently cover
# nothing -- the exact shape of blindness this grow exists to remove.
"$ROOT/tests/.build/sb_poke" "$OUT" 2>/dev/null | grep -q "bg_table_next=[1-9]" || {
    echo "the grown golden has no BG table chain (bg_table_next is 0)" >&2; exit 1; }
losetup -d "$LOOP"; LOOP=""
echo "golden: $OUT (grown, with a BG table chain)"
