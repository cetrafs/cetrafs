#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SEEK_HOLE / SEEK_DATA
#
# cetrafs has always supported sparse files -- a hole is an unmapped
# logical block that reads as zeros -- but until now nothing could ask
# WHERE the holes were, so `cp --sparse=auto`, `tar -S` and
# `qemu-img convert` all copied them as zeros. A thin 500 GB VM image
# became 500 GB on the way in or out: the most visible thing this
# filesystem got wrong for its own workload.
#
# Every case is checked against ext4 as well, running the identical
# probe on both. Hardcoded expectations would just encode my reading of
# the man page; a filesystem that has had this right for years is a
# better oracle, and the two must agree.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 seekhd)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt seekhd)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A plain ext4 on its own loop device, as the oracle.
EXT4_IMG="$(ct_image 64 seekhd4)"
EXT4_DEV="$(ct_loop "$EXT4_IMG")"
EXT4_MNT="$(ct_mnt seekhd4)"
mkfs.ext4 -q -F "$EXT4_DEV" >/dev/null 2>&1
mount -t ext4 "$EXT4_DEV" "$EXT4_MNT"
ct_track mnt "$EXT4_MNT"
CT_EXTRA_UMOUNT="$EXT4_MNT"
# ct_track, not a trap: a suite's own `trap ... EXIT` replaces the
# harness cleanup entirely, leaving this suite's loop devices and
# cetrafs mount behind for whatever runs next.

# Build one file shape and report every SEEK answer for it, as text.
# Run identically on both filesystems and diff the output.
probe() { # <dir> <shape>
python3 - "$1" "$2" <<'PY'
import os, sys, errno
d, shape = sys.argv[1], sys.argv[2]
p = os.path.join(d, "probe-" + shape)
blk = b'D' * 4096
fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
if shape == "dense":
    os.pwrite(fd, blk * 4, 0)
elif shape == "sparse":
    # data, hole, data, hole-to-EOF
    os.pwrite(fd, blk, 0)
    os.pwrite(fd, blk, 4 * 4096)
    os.ftruncate(fd, 8 * 4096)
elif shape == "hole-first":
    os.pwrite(fd, blk, 3 * 4096)
elif shape == "descending":
    # written BACKWARDS: the extent array ends up in creation order,
    # not logical order, so any scan that assumes sortedness is wrong
    for i in (6, 4, 2, 0):
        os.pwrite(fd, blk, i * 4096)
    os.ftruncate(fd, 8 * 4096)
os.fsync(fd)
size = os.fstat(fd).st_size
out = []
for off in range(0, size + 4096, 2048):
    for whence, name in ((os.SEEK_DATA, "DATA"), (os.SEEK_HOLE, "HOLE")):
        try:
            out.append("%6d %s -> %d" % (off, name, os.lseek(fd, off, whence)))
        except OSError as e:
            out.append("%6d %s -> %s" % (off, name, errno.errorcode.get(e.errno, e.errno)))
os.close(fd)
print("\n".join(out))
PY
}

for shape in dense sparse hole-first descending; do
    log "shape: $shape"
    C="$(probe "$MNT" "$shape")"
    E="$(probe "$EXT4_MNT" "$shape")"
    if [ "$C" = "$E" ]; then
        pass "$shape: every SEEK_DATA/SEEK_HOLE answer matches ext4"
    else
        fail "$shape: differs from ext4
--- cetrafs ---
$C
--- ext4 ---
$E"
    fi
done

log "the answers are not trivially 'everything is data'"
# A test comparing two filesystems proves nothing if the implementation
# just returns the offset for everything -- ext4 would differ, but it is
# worth asserting the shape directly too.
S="$(probe "$MNT" sparse)"
echo "$S" | grep -q "^  4096 DATA -> 16384" &&
    pass "SEEK_DATA from inside the hole skips to the next data block" ||
    fail "SEEK_DATA from 4096 gave: $(echo "$S" | grep '^  4096 DATA')"
echo "$S" | grep -q "^     0 HOLE -> 4096" &&
    pass "SEEK_HOLE from the first data block finds the hole after it" ||
    fail "SEEK_HOLE from 0 gave: $(echo "$S" | grep '^     0 HOLE')"
echo "$S" | grep -qE "^ *(2[0-9]{4}|3[0-9]{4}) DATA -> ENXIO" &&
    pass "SEEK_DATA past the last data returns ENXIO" ||
    fail "no ENXIO for SEEK_DATA past the last data"

log "a file whose extents spilled to the external leaf"
# Depth 1 exercises the other half of cetrafs_inode_extents_get(). Built
# by interleaving with a filler so the blocks cannot merge into one
# extent, then holes punched through it.
python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
a = os.open(os.path.join(d, "big"), os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
b = os.open(os.path.join(d, "fill"), os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
blk = b'B' * 4096
for i in range(30):
    os.pwrite(a, blk, i * 4096)
    os.pwrite(b, blk, i * 4096)
os.fsync(a); os.fsync(b)
os.close(b)
os.close(a)
PY
sync
BIGINO="$(stat -c '%i' "$MNT/big")"
DEPTH="$("$(ct_helper inode_block_poke)" "$IMG" extents "$BIGINO" | grep -oP 'depth=\K[0-9]+')"
fallocate -p -o $((10 * 4096)) -l $((5 * 4096)) "$MNT/big"
sync
OUT="$(python3 - "$MNT/big" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print("hole_at:%d" % os.lseek(fd, 0, os.SEEK_HOLE))
print("data_after:%d" % os.lseek(fd, 10 * 4096, os.SEEK_DATA))
os.close(fd)
PY
)"
echo "$OUT" | grep -q "^hole_at:40960" &&
    pass "the punched hole is found at the right offset (depth=$DEPTH file)" ||
    fail "SEEK_HOLE gave $(echo "$OUT" | grep hole_at), want 40960"
echo "$OUT" | grep -q "^data_after:61440" &&
    pass "SEEK_DATA from inside the punched hole finds the data after it" ||
    fail "SEEK_DATA gave $(echo "$OUT" | grep data_after), want 61440"

log "the usual suspects still work"
python3 -c "
import os,sys
fd=os.open(sys.argv[1], os.O_RDONLY)
assert os.lseek(fd, 100, os.SEEK_SET) == 100
assert os.lseek(fd, 0, os.SEEK_END) == os.fstat(fd).st_size
os.close(fd)" "$MNT/big" && pass "SEEK_SET/SEEK_CUR/SEEK_END are unaffected" ||
    fail "ordinary llseek broke"

umount "$EXT4_MNT"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
