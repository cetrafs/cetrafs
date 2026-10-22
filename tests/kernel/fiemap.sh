#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# FS_IOC_FIEMAP
#
# SEEK_HOLE/SEEK_DATA answered the question the copy tools ask. .fiemap
# answers the one everything else asks: give me the extent map. Without
# it `filefrag` cannot report a layout at all, which is the first thing
# anyone reaches for when a VM image on shared storage feels slow --
# and this filesystem has a whole defragmenter whose work is invisible
# without it.
#
# The map is checked against what the filesystem itself reports through
# other interfaces -- SEEK_DATA/SEEK_HOLE for where the data is, and
# stat for the block count -- so the assertions cannot all be satisfied
# by a map that is internally consistent but wrong.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fiemap)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fiemap)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Ask for the map directly rather than through filefrag, which may not
# be installed: one ioctl, printed as "logical length" pairs.
fiemap() { # <path>
python3 - "$1" <<'PY'
import os, sys, struct, fcntl, array
FS_IOC_FIEMAP = 0xC020660B
FIEMAP_EXTENT_LAST = 0x0001
path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
count = 64
# struct fiemap { u64 start, len; u32 flags, mapped, count, reserved; }
buf = array.array('B', struct.pack('<QQIIII', 0, 1 << 62, 0, 0, count, 0) + b'\0' * (56 * count))
try:
    fcntl.ioctl(fd, FS_IOC_FIEMAP, buf, True)
except OSError as e:
    # sys.stdout.flush() before _exit: os._exit bypasses stdio flushing,
    # so the error line was being LOST and the caller saw an empty
    # result instead of "ERR 95" -- which made a suite run against a
    # kernel with no .fiemap die with no output at all.
    print("ERR %s" % e.errno)
    sys.stdout.flush()
    os._exit(0)
mapped = struct.unpack_from('<I', buf, 20)[0]
out = []
for i in range(mapped):
    off = 32 + i * 56
    logical, physical, length, _r1, _r2, flags = struct.unpack_from('<QQQQQI', buf, off)
    out.append("%d %d %s" % (logical, length, "LAST" if flags & FIEMAP_EXTENT_LAST else "-"))
print("\n".join(out))
os.close(fd)
PY
}

log "a dense file maps as one extent"
dd if=/dev/zero of="$MNT/dense" bs=4096 count=16 status=none
sync
OUT="$(fiemap "$MNT/dense")"
# An explicit branch, not `grep && fail`: fail returns nonzero and under
# `set -e` that aborts the suite mid-run, which reads as a hang rather
# than a result. Measured -- with .fiemap removed the suite ended after
# two assertions and printed no FAIL at all.
if echo "$OUT" | grep -q "^ERR"; then
    fail "fiemap is not implemented (errno $(echo "$OUT" | cut -d' ' -f2))"
    ct_exit
fi
N="$(echo "$OUT" | grep -c .)"
[ "$N" = "1" ] && pass "a 16-block contiguous file reports one extent" ||
    fail "reported $N extents for a contiguous file: $OUT"
echo "$OUT" | grep -q "^0 65536 LAST" &&
    pass "...covering the whole file, flagged LAST" || fail "unexpected extent: $OUT"

log "a sparse file reports only its data, and the holes are absent"
python3 - "$MNT/sparse" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
blk = b'S' * 4096
os.pwrite(fd, blk, 0)
os.pwrite(fd, blk, 4 * 4096)
os.ftruncate(fd, 8 * 4096)
os.fsync(fd); os.close(fd)
PY
sync
OUT="$(fiemap "$MNT/sparse")"
[ "$(echo "$OUT" | grep -c .)" = "2" ] && pass "two data regions are reported" ||
    fail "expected 2 extents, got: $OUT"
echo "$OUT" | head -1 | grep -q "^0 4096" && pass "the first is at offset 0" || fail "first extent: $(echo "$OUT" | head -1)"
echo "$OUT" | tail -1 | grep -q "^16384 4096 LAST" &&
    pass "the second is at 16384 and is flagged LAST" || fail "second extent: $(echo "$OUT" | tail -1)"

log "the map agrees with what SEEK_DATA/SEEK_HOLE say"
# The cross-check that makes this more than an internal-consistency
# test: two independent interfaces over the same extent tree must give
# the same picture.
AGREE="$(python3 - "$MNT/sparse" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print("data0:%d" % os.lseek(fd, 0, os.SEEK_DATA))
print("hole0:%d" % os.lseek(fd, 0, os.SEEK_HOLE))
print("data1:%d" % os.lseek(fd, 4096, os.SEEK_DATA))
os.close(fd)
PY
)"
echo "$AGREE" | grep -q "^data0:0" && echo "$AGREE" | grep -q "^hole0:4096" &&
    echo "$AGREE" | grep -q "^data1:16384" &&
    pass "SEEK agrees with the map: data at 0, hole at 4096, data again at 16384" ||
    fail "SEEK and fiemap disagree: $AGREE"

log "a depth-1 file (extents in the external leaf)"
python3 - "$MNT/big" "$MNT/filler" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
b = os.open(sys.argv[2], os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
blk = b'B' * 4096
for i in range(30):
    os.pwrite(a, blk, i * 4096)
    os.pwrite(b, blk, i * 4096)
os.fsync(a); os.fsync(b); os.close(b); os.close(a)
PY
sync
BINO="$(stat -c '%i' "$MNT/big")"
DEPTH="$("$IPOKE" "$IMG" extents "$BINO" | grep -oP 'depth=\K[0-9]+')"
OUT="$(fiemap "$MNT/big")"
NE="$(echo "$OUT" | grep -c .)"
[ "$NE" -ge 1 ] && pass "a depth=$DEPTH file reports $NE extent(s)" || fail "no extents: $OUT"
TOT="$(echo "$OUT" | awk '{s+=$2} END{print s}')"
[ "$TOT" = "$((30 * 4096))" ] && pass "the extents cover exactly the file's 30 blocks" ||
    fail "extents total $TOT bytes, file is $((30 * 4096))"
echo "$OUT" | tail -1 | grep -q "LAST" && pass "the final extent is flagged LAST" ||
    fail "no LAST flag: $(echo "$OUT" | tail -1)"

log "a backwards-written file: the stored extent array is NOT in logical order"
# cetrafs_leaf_array_insert() appends and never sorts, so a file written
# at descending offsets stores its extents reversed from logical order.
# fiemap considers every entry per emitted extent precisely because of
# that -- an "optimization" that assumed the array ordered would emit a
# wrong map here and nowhere else in this suite. Assert the STRUCTURE
# first: if an allocator change ever makes this file come
# out logically ordered, these assertions silently stop covering the
# unordered case, and the structure check is what says so.
python3 - "$MNT/backwards" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
blk = b'R' * 4096
for i in (3, 2, 1, 0):
    os.pwrite(fd, blk, i * 4096)
os.fsync(fd); os.close(fd)
PY
sync
RINO="$(stat -c '%i' "$MNT/backwards")"
RSHAPE="$("$IPOKE" "$IMG" extents "$RINO")"
FIRST_EE="$(echo "$RSHAPE" | grep -oP '^ext 0 logical=\K[0-9]+' || echo "")"
if [ -n "$FIRST_EE" ] && [ "$FIRST_EE" != "0" ]; then
    pass "structure: the first STORED extent is logical block $FIRST_EE, not 0 -- the array is really unordered"
else
    fail "the backwards file came out ordered (first stored extent: '$FIRST_EE') -- the assertions below cover nothing: $RSHAPE"
fi
OUT="$(fiemap "$MNT/backwards")"
NB="$(echo "$OUT" | grep -c .)"
[ "$NB" = "4" ] && pass "four one-block extents are reported" || fail "expected 4 extents: $OUT"
# ascending logical order, regardless of stored order
echo "$OUT" | awk '{ if ($1 < prev) exit 1; prev = $1 } END { exit 0 }' &&
    pass "the map is emitted in ascending logical order" || fail "map out of order: $OUT"
echo "$OUT" | head -1 | grep -q "^0 4096" && echo "$OUT" | tail -1 | grep -q "^12288 4096 LAST" &&
    pass "it starts at 0 and the extent at 12288 -- stored FIRST -- is the one flagged LAST" ||
    fail "wrong first/last extent: $OUT"
TOTB="$(echo "$OUT" | awk '{s+=$2} END{print s}')"
[ "$TOTB" = "$((4 * 4096))" ] && pass "the extents cover exactly the file's 4 blocks" ||
    fail "extents total $TOTB bytes, file is $((4 * 4096))"

log "an empty file maps nothing, and a directory is refused"
: >"$MNT/empty"
sync
[ -z "$(fiemap "$MNT/empty" | grep -v '^$' || true)" ] &&
    pass "an empty file reports no extents" || fail "empty file reported: $(fiemap "$MNT/empty")"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
