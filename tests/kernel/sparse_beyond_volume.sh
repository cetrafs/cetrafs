#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a sparse file may be larger than the volume (audit 2026-11-14 F6)
#
# A file's ceiling is the format's, 2^60 bytes (2^48 logical blocks), not the
# volume's capacity. ext4, xfs and VMFS all hold a thin image bigger than
# the datastore it lives on; refusing it with EFBIG was the old policy,
# kept as a TEST ONLY knob (cap_file_to_volume) so the control below can
# show the cap was real and that the new behaviour is the lifted one.
#
# Asserted, on a 600 MiB volume:
#   - truncate to 4 TiB, write at its far end, read it back;
#   - write at 2^60 - 4 KiB, the last addressable block, and read it back,
#     with SEEK_DATA walking the map there and an O_DIRECT write beside it;
#   - fallocate far past the free space fails ENOSPC, not EFBIG, and the
#     data already on the volume is intact;
#   - a sequential write past the free space ends in ENOSPC with the
#     accepted prefix intact (no wrap, no corruption);
#   - fsck is clean after all of it;
#   - truncate past 2^60 is still refused.
# The control (cap_file_to_volume=1) must refuse the 4 TiB truncate and the
# far write with EFBIG, which proves the knob reaches the same checks.
#
# DISCRIMINATION: with the capacity cap put back (the knob) the first
# assertions fail with EFBIG; with fs.c's cetrafs_sb_max_file_size() made
# to return the capacity unconditionally, the lifted cases fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 600 sparsebig)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt sparsebig)"
ct_track mnt "$MNT"

ct_mkfs "$DEV" -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# Setup: the volume really is smaller than the file we are about to make.
VOLB="$(df -Pk "$MNT" | awk 'NR==2 {print $2 * 1024}')"
[ "$VOLB" -gt 0 ] && [ "$VOLB" -lt $((1024 * 1024 * 1024)) ] ||
    { fail "setup: the volume is $VOLB bytes, not under 1 GiB -- nothing below would test a file bigger than the volume"; ct_exit; }

TB4=$((4 * 1024 * 1024 * 1024 * 1024))
CEIL=$((1 << 60)) # the format ceiling: 2^48 blocks of 4 KiB (v0x000A)

# ----------------------------------------------- the lifted ceiling, default
R="$(python3 - "$MNT/thin" "$TB4" <<'PY'
import os, sys
path, size = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
try:
    os.ftruncate(fd, size)
    off = size - 4096
    os.pwrite(fd, b"FAR!" * 1024, off)
    os.fsync(fd)
    ok = os.pread(fd, 4, off) == b"FAR!" and os.pread(fd, 4, 0) == b"\0\0\0\0"
    print("OK" if ok and os.fstat(fd).st_size == size else "WRONG")
except OSError as e:
    import errno
    print(errno.errorcode.get(e.errno, str(e.errno)))
    sys.stdout.flush()
finally:
    os.close(fd)
PY
)"
[ "$R" = "OK" ] && pass "a 4 TiB sparse file on a 600 MiB volume: truncate, far write and read-back work" ||
    fail "4 TiB sparse file on a 600 MiB volume gave '$R'"

R="$(python3 - "$MNT/thin" "$CEIL" <<'PY'
import os, sys, errno
path, size = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR)
try:
    off = size - 4096
    os.pwrite(fd, b"TOP!" * 1024, off)
    os.fsync(fd)
    # SEEK_DATA walks the sparse map out here: the first data is the
    # 4 TiB block, the next is the top block.
    far = 4 * 1024 * 1024 * 1024 * 1024 - 4096
    seek_ok = os.lseek(fd, 0, os.SEEK_DATA) == far and os.lseek(fd, far + 4096, os.SEEK_DATA) == off
    # O_DIRECT at the far end as well: the same ceiling, another path.
    import mmap
    dfd = os.open(path, os.O_RDWR | os.O_DIRECT)
    buf = mmap.mmap(-1, 4096)
    buf.write(b"DIO!" * 1024)
    os.pwrite(dfd, buf, off - 8192)
    os.close(dfd)
    dio_ok = os.pread(fd, 4, off - 8192) == b"DIO!"
    print("OK" if os.pread(fd, 4, off) == b"TOP!" and os.pread(fd, 4, 4 * 1024 * 1024 * 1024 * 1024 - 4096) == b"FAR!"
          and seek_ok and dio_ok else "WRONG seek=%s dio=%s" % (seek_ok, dio_ok))
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
    sys.stdout.flush()
finally:
    os.close(fd)
PY
)"
[ "$R" = "OK" ] && pass "the last addressable block (2^60 - 4 KiB) is writable; SEEK_DATA and O_DIRECT reach it too" ||
    fail "write at 2^60 - 4 KiB gave '$R'"

# The format ceiling itself still holds: past it is EFBIG.
if truncate -s $((CEIL + 4096)) "$MNT/over" 2>/dev/null; then
    fail "truncate past the format ceiling was accepted"
else
    pass "truncate past the format ceiling is refused"
fi

# ------------------------------------------------ ENOSPC past the free space
# Put real data on the volume first, so a clean ENOSPC can be checked
# against something that must survive it.
head -c $((64 * 1024 * 1024)) /dev/urandom >"$MNT/keep"
sync
KEEPSUM="$(sha256sum <"$MNT/keep")"

R="$(python3 - "$MNT/fill" <<'PY'
import os, sys, errno
path = sys.argv[1]
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
chunk = bytes(range(256)) * 4096          # 1 MiB, a known pattern
done = 0
err = "none"
try:
    for i in range(1024):                  # up to 1 GiB, past the volume
        try:
            n = os.pwrite(fd, chunk, done)
        except OSError as e:
            err = errno.errorcode.get(e.errno, str(e.errno))
            break
        done += n
        if n != len(chunk):
            # A short write is the partial result; the next one must
            # be the refusal that ends it.
            try:
                os.pwrite(fd, chunk[:4096], done)
                err = "none"
            except OSError as e:
                err = errno.errorcode.get(e.errno, str(e.errno))
            break
    os.fsync(fd)
    ok = True
    back = os.pread(fd, len(chunk), 0) == chunk if done >= len(chunk) else True
    print("ERR=%s DONE=%d BACK=%s" % (err, done, "yes" if back else "NO"))
except OSError as e:
    print("ERR=%s DONE=%d BACK=n/a" % (errno.errorcode.get(e.errno, str(e.errno)), done))
finally:
    os.close(fd)
PY
)"
# Setup: the fill must have placed a real prefix before the refusal, or
# "prefix intact" is measured over nothing.
DONE="$(sed -n 's/.*DONE=\([0-9]*\).*/\1/p' <<<"$R")"
case "$R" in
*ERR=ENOSPC*BACK=yes*)
    if [ "${DONE:-0}" -gt $((64 * 1024 * 1024)) ]; then
        pass "a sequential write past the free space ends ENOSPC with its prefix intact ($R)"
    else
        fail "setup: the fill placed only ${DONE:-0} bytes before ENOSPC -- nothing was measured"
    fi ;;
*) fail "sequential write past the free space: $R" ;;
esac

[ "$(sha256sum <"$MNT/keep")" = "$KEEPSUM" ] &&
    pass "the data written before the volume filled is intact after the ENOSPC" ||
    fail "data written before the volume filled changed after the ENOSPC"

# Only after the fill: fallocate on the full volume is the refusal under test.
R="$(python3 - "$MNT/fallo" <<'PY'
import os, sys, errno
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
try:
    os.posix_fallocate(fd, 0, 2 * 1024 * 1024 * 1024)
    print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
    sys.stdout.flush()
finally:
    os.close(fd)
PY
)"
[ "$R" = "ENOSPC" ] && pass "fallocate of 2 GiB on a 600 MiB volume fails ENOSPC" ||
    fail "fallocate of 2 GiB on a 600 MiB volume gave '$R', not ENOSPC"

# ------------------------------------------- the control: the cap, put back
ct_param_set cap_file_to_volume 1
R="$(python3 - "$MNT/capped" "$TB4" <<'PY'
import os, sys, errno
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
try:
    os.ftruncate(fd, int(sys.argv[2]))
    print("ACCEPTED")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
    sys.stdout.flush()
finally:
    os.close(fd)
PY
)"
[ "$R" = "EFBIG" ] && pass "control: with the capacity cap restored, a 4 TiB truncate is refused EFBIG" ||
    fail "control: with the capacity cap restored the 4 TiB truncate gave '$R', not EFBIG"
ct_param_set cap_file_to_volume 0

# ---------------------------------------------------------- fsck after all
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after the thin files and the ENOSPC" ||
    fail "fsck: $(grep -m3 -i 'err\|bad\|leak' <<<"$out" | tr '\n' ' ')"
ct_exit
