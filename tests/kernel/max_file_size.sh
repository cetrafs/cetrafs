#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# s_maxbytes must respect the FORMAT's ceiling, and no logical block may alias
#
# A logical block is 48 bits (v0x000A, M-42): a file reaches 2^48 blocks,
# 2^60 bytes. When it was 32 bits, s_maxbytes was once computed from
# capacity alone, and on a 17 TiB volume a write at 16 TiB truncated its
# block number and ALIASED offset 0 of the same file (measured: bytes
# written at 16 TiB read back at offset 0). Every logical block is u64
# now; this crosses the old 2^32 boundary and goes to the new one.
#
# A file is bounded by the format, not by its volume (F6), so all of it
# runs as sparse writes on an ordinary 1 GiB volume:
#   1. s_maxbytes is 2^60;
#   2. a write at block 2^32, and at 2^32 + 1, reads back where it was
#      written, and the blocks a 32-bit truncation would alias them to
#      (0 and 1) read as holes;
#   3. the last block, 2^48 - 1, likewise (its 32-bit alias is 2^32 - 1);
#   4. block 2^48 is refused with EFBIG, and so is a truncate past 2^60;
#      a truncate to exactly 2^60 is accepted.
#
# DISCRIMINATION: on the 32-bit format 1 reads 2^44, and 2 and 3 are
# refused with EFBIG; a truncation anywhere on the write path would put
# the pattern on the alias block, which 2 and 3 read.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

CEILING=1152921504606846976 # 2^48 blocks * 4096

SIMG="$(ct_image 1200 mfssmall)"
SDEV="$(ct_loop "$SIMG")"
SMNT="$(ct_mnt mfssmall)"
ct_mkfs "$SDEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$SDEV" "$SMNT"
require_cetrafs_mount "$SMNT"

SMAX="$(sed -n 's/^max_file_size_bytes: //p' "$(ct_procdir "$SDEV")/info" 2>/dev/null || echo 0)"
[ "$SMAX" = "$CEILING" ] &&
    pass "1: s_maxbytes is the 48-bit format ceiling ($SMAX), not the volume's capacity" ||
    fail "1: max_file_size_bytes=$SMAX, expected $CEILING"

# <file> <block> <alias block>: write a pattern at <block>, fsync, drop the
# caches, and report what <block> and <alias block> hold.
probe() {
    python3 -I - "$SMNT/$1" "$2" "$3" <<'PY'
import errno, os, sys
path, blk, alias = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
pat = (b"B%015d" % blk) * 256
try:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    os.pwrite(fd, pat, blk * 4096)
    os.fsync(fd)
    os.close(fd)
except OSError as e:
    print("REFUSED:" + errno.errorcode.get(e.errno, str(e.errno)))
    sys.exit(0)
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3")
fd = os.open(path, os.O_RDONLY)
here = os.pread(fd, 4096, blk * 4096)
there = os.pread(fd, 4096, alias * 4096)
os.close(fd)
print("here=%s alias=%s" % ("ok" if here == pat else "zero" if here == b"\0" * 4096 else "other",
                            "zero" if there == b"\0" * 4096 else "DATA"))
PY
}
for b in 4294967296 4294967297; do
    R="$(probe at32 "$b" $((b - 4294967296)))"
    [ "$R" = "here=ok alias=zero" ] &&
        pass "2: block $b reads back where it was written, and its 32-bit alias is a hole" ||
        fail "2: block $b: $R"
done
R="$(probe last 281474976710655 4294967295)"
[ "$R" = "here=ok alias=zero" ] &&
    pass "3: the last block (2^48 - 1) reads back, and its 32-bit alias is a hole" ||
    fail "3: block 2^48 - 1: $R"
R="$(probe past 281474976710656 0)"
[ "$R" = "REFUSED:EFBIG" ] && pass "4: a write at block 2^48 is refused with EFBIG" ||
    fail "4: a write at block 2^48 gave: $R"
# truncate(2) is a different VFS path (setattr_prepare).
if truncate -s $((CEILING + 4096)) "$SMNT/trunc" 2>/dev/null; then
    fail "4: truncate past the format ceiling was accepted"
else
    pass "4: truncate past the format ceiling is refused"
fi
truncate -s "$CEILING" "$SMNT/trunc" 2>/dev/null &&
    pass "4: truncate to exactly the ceiling is accepted" ||
    fail "4: truncate to exactly the ceiling was refused -- the clamp is off by one"
rm -f "$SMNT/at32" "$SMNT/last" "$SMNT/past" "$SMNT/trunc"

# 5. preallocated extents across 2^32, at depth 2, written in the middle.
#
# Writing into a preallocated extent finds the leaf holding it by a test
# on each leaf, and a middle write splits the extent in three, so full
# leaves are split around a pivot block sorted out of the leaf. Both read
# the block number back through a void pointer, which no cast or
# compiler warning shows: after M-42 widened it to u64 they still read
# 32 bits, so past 2^32 the leaf test looked for the wrong block and the
# sort ordered keys by their low half. 300 four-block extents at a
# stride of 8 straddle 2^32 (more than one leaf's 254, so depth 2); the
# second block of each is written.
log "preallocated extents across 2^32 at depth 2, each written in its middle"
OUT="$(python3 -I - "$SMNT/prealloc" <<'PY'
import ctypes, errno, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
B, N, S = 2 ** 32 - 150 * 8, 300, 8
pat = lambda b: (b"P%015d" % b) * 256
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
for i in range(N):
    if libc.fallocate(fd, 0, (B + S * i) * 4096, 4 * 4096) != 0:
        print("SETUP: fallocate %d failed: %s" % (i, errno.errorcode.get(ctypes.get_errno())))
        sys.exit(0)
os.fsync(fd)
errs = []
for i in range(N):
    b = B + S * i + 1
    try:
        os.pwrite(fd, pat(b), b * 4096)
    except OSError as e:
        errs.append("write at block %d: %s" % (b, errno.errorcode.get(e.errno)))
        break
os.fsync(fd)
os.close(fd)
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3")
fd = os.open(sys.argv[1], os.O_RDONLY)
size = os.fstat(fd).st_size  # the last extent ends the file: its gap after is past EOF
for i in range(N):
    for k in range(S):
        b = B + S * i + k
        got = os.pread(fd, 4096, b * 4096)
        want = b"" if b * 4096 >= size else pat(b) if k == 1 else b"\0" * 4096
        if got != want:
            errs.append("block %d (extent %d +%d) reads wrong" % (b, i, k))
    if len(errs) > 5:
        break
os.close(fd)
print("\n".join(errs) if errs else "OK")
sys.stdout.flush()
PY
)" || true
NEXT="$(filefrag "$SMNT/prealloc" 2>/dev/null | sed -n 's/.*: \([0-9]*\) extents\{0,1\} found/\1/p')"
case "$OUT" in
SETUP:*) fail "5 setup: $OUT" ;;
*)
    if [ "${NEXT:-0}" -le 258 ]; then
        fail "5 setup: the file has ${NEXT:-?} extents -- not more than depth 1 holds, so no depth-2 tree was built"
    else
        [ "$OUT" = OK ] &&
            pass "5: $NEXT extents across 2^32 at depth 2, each written mid-preallocation, read back in place" ||
            fail "5: $(printf '%s' "$OUT" | head -6 | tr '\n' ';')"
    fi
    ;;
esac
rm -f "$SMNT/prealloc"

# ------------------------------------------------- the ordinary volume
# F6: a file is bounded by the format, not by the volume it lives on. A
# sparse file may be larger than the volume (sparse_beyond_volume.sh); the
# TEST ONLY knob puts the old capacity cap back for the control.
if truncate -s $((2 * 1024 * 1024 * 1024)) "$SMNT/bigsparse" 2>/dev/null; then
    pass "a 2 GiB sparse file on a 1 GiB volume is accepted"
else
    fail "a 2 GiB sparse file on a 1 GiB volume was refused"
fi
ct_param_set cap_file_to_volume 1
if truncate -s $((2 * 1024 * 1024 * 1024)) "$SMNT/capped" 2>/dev/null; then
    fail "control: with the capacity cap restored, a 2 GiB file on a 1 GiB volume was accepted"
else
    pass "control: with the capacity cap restored, a 2 GiB file on a 1 GiB volume is refused"
fi
ct_param_set cap_file_to_volume 0

# ------------------------------------------------------- forced noatime
#
# SB_NOATIME is forced at mount because an atime update dirties an inode
# record and writeback blind-writes that record with no cross-node lock
# held. Audited, not fixed: the atime options are mount-point attributes
# in this kernel, so reconfigure_super() never has SB_NOATIME in its
# change mask and cannot clear it. Asserted because "holds by
# construction" is only worth anything if something notices when it
# stops holding.
log "checking atime stays off, including across a remount that asks for it"
echo content >"$SMNT/atimef"
sync
A1="$(stat -c %X "$SMNT/atimef")"
sleep 2
cat "$SMNT/atimef" >/dev/null
sync
A2="$(stat -c %X "$SMNT/atimef")"
[ "$A1" = "$A2" ] && pass "noatime: a read does not update atime" ||
    fail "noatime: atime moved $A1 -> $A2 on a plain read"
mount -o remount,strictatime "$SMNT" 2>/dev/null || true
sleep 2
cat "$SMNT/atimef" >/dev/null
sync
A3="$(stat -c %X "$SMNT/atimef")"
[ "$A2" = "$A3" ] &&
    pass "noatime: survives a remount that explicitly asks for strictatime" ||
    fail "noatime: remount,strictatime turned atime back on ($A2 -> $A3) -- every read now dirties a record"
ct_umount "$SMNT"

ct_exit
