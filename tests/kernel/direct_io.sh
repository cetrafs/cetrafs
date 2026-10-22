#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# O_DIRECT
#
# Without .direct_IO the VFS refuses O_DIRECT at open with -EINVAL, so a
# qemu guest configured cache=none -- Proxmox VE's DEFAULT disk cache
# mode, and the one recommended for shared storage -- cannot open its
# image at all.
#
# The interesting assertions here are not "it works" but the three ways
# direct I/O can be subtly wrong on a filesystem like this one: a
# sub-block write into a freshly allocated block exposing whatever that
# block held before, the cross-node lock not being taken because the
# open took a different path, and buffered and direct access to the same
# file disagreeing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 dio)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dio)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Shared python preamble: O_DIRECT needs the buffer, offset and length
# aligned, so every case allocates through mmap and offsets to a 4 KiB
# boundary itself.
PRE='
import os, sys, mmap, ctypes, errno, random
def ab(n, align=4096):
    b = mmap.mmap(-1, n + align)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % align
def mv(b, o, n):
    return memoryview(b)[o:o+n]
mnt = sys.argv[1]
'

log "O_DIRECT opens, and the basic shape works"
# Tolerate a failure here rather than letting `set -e` abort the suite:
# with no .direct_IO the open itself raises EINVAL, and a silent abort
# is the failure mode this project has been bitten by before.
OUT="$(python3 -c "$PRE"'
p = mnt + "/basic"
try:
    fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
except OSError as e:
    print("openfail:%s" % errno.errorcode.get(e.errno, e.errno)); sys.exit(0)
b, o = ab(4096); b[o:o+4096] = b"D" * 4096
print("write:%d" % os.pwrite(fd, mv(b,o,4096), 0))
print("write2:%d" % os.pwrite(fd, mv(b,o,4096), 8192))
r, ro = ab(4096)
print("read:%d" % os.preadv(fd, [mv(r,ro,4096)], 0))
print("content:%s" % bytes(r[ro:ro+4]).decode())
os.preadv(fd, [mv(r,ro,4096)], 4096)
print("hole:%s" % ("zeros" if bytes(r[ro:ro+4096]) == b"\0"*4096 else "NOTZERO"))
os.close(fd)
' "$MNT")"
echo "$OUT" | grep -q "^write:4096" && pass "an O_DIRECT open succeeds and a 4 KiB write returns 4096" ||
    fail "O_DIRECT write: $OUT"
echo "$OUT" | grep -q "^read:4096" && echo "$OUT" | grep -q "^content:DDDD" &&
    pass "the data reads back through O_DIRECT" || fail "O_DIRECT read: $OUT"
echo "$OUT" | grep -q "^hole:zeros" && pass "a hole reads as zeros through O_DIRECT" ||
    fail "a hole read gave: $(echo "$OUT" | grep hole)"

log "a sub-block write into a NEW block must not expose what the block held"
# The device reports 512-byte logical blocks, so the DIO path permits
# 512-granular I/O while cetrafs allocates in 4 KiB units. A 512-byte
# write that ALLOCATES therefore covers one eighth of a fresh block --
# and the rest is whatever the previous owner left there. What makes
# that safe is cetrafs_get_block() calling set_buffer_new(), which the
# DIO path honours by zeroing the uncovered remainder. Removing that
# call turns this into a cross-file information leak.
OUT="$(python3 -c "$PRE"'
v = os.open(mnt + "/victim", os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(v, b"SECRET!!" * 512 * 16, 0)
os.fsync(v); os.close(v)
os.unlink(mnt + "/victim")
os.system("sync")
f = os.open(mnt + "/thief", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
b, o = ab(512); b[o:o+512] = b"A" * 512
os.pwrite(f, mv(b,o,512), 3584)   # last sector of a fresh block
os.close(f)
os.system("sync")
d = open(mnt + "/thief", "rb").read()
print("len:%d" % len(d))
print("written:%s" % ("yes" if d[3584:3592] == b"A"*8 else "no"))
print("leak:%s" % ("YES" if b"SECRET" in d else "no"))
print("zeroed:%s" % ("yes" if d[:3584] == b"\0"*3584 else "no"))
' "$MNT")"
echo "$OUT" | grep -q "^written:yes" && pass "the 512-byte sub-block write landed where it was aimed" ||
    fail "the sub-block write: $OUT"
echo "$OUT" | grep -q "^leak:no" &&
    pass "the rest of the freshly allocated block does not expose the deleted file's data" ||
    fail "a deleted file's contents are readable through a sub-block O_DIRECT write: $OUT"
echo "$OUT" | grep -q "^zeroed:yes" && pass "...it is zero-filled, as set_buffer_new() requires" ||
    fail "the uncovered part of the new block is not zeroed: $OUT"

log "the cross-node exclusive lock is taken for an O_DIRECT write-open"
: >"$MNT/locked"
INO="$(stat -c '%i' "$MNT/locked")"
sync
OUT="$(python3 -c "$PRE"'
import subprocess
lp, img, ino = sys.argv[2], sys.argv[3], sys.argv[4]
def lock(): return subprocess.run([lp, img, ino], capture_output=True, text=True).stdout.strip()
print("before:" + lock())
fd = os.open(mnt + "/locked", os.O_RDWR | os.O_DIRECT)
print("during:" + lock())
os.close(fd)
print("after:" + lock())
' "$MNT" "$LOCK_POKE" "$IMG" "$INO")"
echo "$OUT" | grep -q "^during:owner=0 mode=1" &&
    pass "an O_DIRECT write-open claims the file, exactly as a buffered one does" ||
    fail "the lock was not claimed: $(echo "$OUT" | grep during)"
echo "$OUT" | grep -q "^after:owner=65535" && pass "and its close releases it" ||
    fail "the lock survived the close: $(echo "$OUT" | grep after)"

log "buffered and direct access to one file agree"
OUT="$(python3 -c "$PRE"'
f = os.open(mnt + "/mix", os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(f, b"M" * 8192, 0)           # buffered, deliberately unflushed
os.close(f)
f = os.open(mnt + "/mix", os.O_RDONLY | os.O_DIRECT)
r, ro = ab(8192)
os.preadv(f, [mv(r,ro,8192)], 0)
print("dio_sees_buffered:%s" % ("yes" if bytes(r[ro:ro+8192]) == b"M"*8192 else "no"))
os.close(f)
f = os.open(mnt + "/mix2", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
b, o = ab(4096); b[o:o+4096] = b"N" * 4096
os.pwrite(f, mv(b,o,4096), 0)
os.close(f)
print("buffered_sees_dio:%s" % ("yes" if open(mnt + "/mix2","rb").read() == b"N"*4096 else "no"))
' "$MNT")"
echo "$OUT" | grep -q "^dio_sees_buffered:yes" &&
    pass "an O_DIRECT read sees a buffered write that was never flushed" ||
    fail "$OUT"
echo "$OUT" | grep -q "^buffered_sees_dio:yes" &&
    pass "a buffered read sees an O_DIRECT write" || fail "$OUT"

log "a sparse file: writes into holes, and large transfers"
OUT="$(python3 -c "$PRE"'
f = os.open(mnt + "/sparse", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
b, o = ab(4096); b[o:o+4096] = b"E" * 4096
os.pwrite(f, mv(b,o,4096), 65536)
os.ftruncate(f, 131072)
os.pwrite(f, mv(b,o,4096), 8192)      # a hole strictly inside i_size
os.close(f)
os.system("sync")
d = open(mnt + "/sparse","rb").read()
print("filled:%s" % ("yes" if d[8192:12288] == b"E"*4096 else "no"))
print("far:%s" % ("yes" if d[65536:69632] == b"E"*4096 else "no"))
print("untouched_zero:%s" % ("yes" if d[16384:65536] == b"\0"*(65536-16384) else "no"))
f = os.open(mnt + "/big", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
N = 1024*1024
b, o = ab(N); b[o:o+N] = b"L" * N
os.pwrite(f, mv(b,o,N), 0)
r, ro = ab(N)
os.preadv(f, [mv(r,ro,N)], 0)
print("mib:%s" % ("yes" if bytes(r[ro:ro+N]) == b"L"*N else "no"))
os.close(f)
' "$MNT")"
echo "$OUT" | grep -q "^filled:yes" && pass "an O_DIRECT write into an interior hole lands" || fail "$OUT"
echo "$OUT" | grep -q "^untouched_zero:yes" && pass "the rest of the sparse file is still a hole" || fail "$OUT"
echo "$OUT" | grep -q "^mib:yes" && pass "a 1 MiB multi-block transfer round-trips" || fail "$OUT"

log "a qemu-shaped workload against a shadow copy"
OUT="$(python3 -c "$PRE"'
SZ = 4 * 1024 * 1024
f = os.open(mnt + "/vm.raw", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
b, o = ab(4096)
shadow = bytearray(SZ)
random.seed(7)
for i in range(SZ // 4096):
    pat = bytes([i % 251]) * 4096
    b[o:o+4096] = pat
    os.pwrite(f, mv(b,o,4096), i * 4096)
    shadow[i*4096:(i+1)*4096] = pat
for _ in range(400):
    i = random.randrange(SZ // 4096)
    pat = bytes([random.randrange(256)]) * 4096
    b[o:o+4096] = pat
    os.pwrite(f, mv(b,o,4096), i * 4096)
    shadow[i*4096:(i+1)*4096] = pat
os.fsync(f)
os.close(f)
os.system("sync")
print("identical:%s" % ("yes" if open(mnt + "/vm.raw","rb").read() == bytes(shadow) else "no"))
' "$MNT")"
echo "$OUT" | grep -q "^identical:yes" &&
    pass "a 4 MiB image, 1024 sequential + 400 random O_DIRECT writes, byte-identical" ||
    fail "the image does not match the shadow: $OUT"

log "it survives a remount, and truncate/punch still work under it"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
python3 -c "$PRE"'
d = open(mnt + "/vm.raw","rb").read()
sys.exit(0 if len(d) == 4*1024*1024 else 1)' "$MNT" &&
    pass "the image is intact after a remount" || fail "the image changed across a remount"
truncate -s 1048576 "$MNT/vm.raw"
[ "$(stat -c '%s' "$MNT/vm.raw")" = "1048576" ] && pass "truncate works on a file written with O_DIRECT" ||
    fail "truncate gave $(stat -c '%s' "$MNT/vm.raw")"
fallocate -p -o 4096 -l 8192 "$MNT/vm.raw" && pass "punch-hole works on it too" ||
    fail "punch-hole failed"

log "O_DIRECT on a directory is still refused"
python3 -c "
import os, sys, errno
try:
    os.close(os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_DIRECT))
    sys.exit(1)
except OSError:
    sys.exit(0)" "$MNT" && pass "a directory cannot be opened O_DIRECT" ||
    fail "O_DIRECT on a directory was allowed"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
