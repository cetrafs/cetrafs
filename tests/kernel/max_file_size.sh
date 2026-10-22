#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# s_maxbytes must respect the FORMAT's ceiling, not just the volume's
#
# cetrafs_extent_t.ee_block is 32 bits, so a file's logical blocks stop
# being addressable past 2^32 -- 16 TiB at 4 KiB blocks -- however much
# capacity the volume has. s_maxbytes was computed purely from capacity
# and clamped only at MAX_LFS_FILESIZE (8 EiB), so on a volume larger
# than 16 TiB the VFS happily admitted a write past the limit, the
# logical block number truncated into the u32, and the extent ALIASED a
# low offset of the same file.
#
# Measured before the fix on a 17 TiB volume: 4 KiB written at offset
# 16 TiB read back at offset 0, with i_size claiming 17592186048512.
# Silent cross-offset corruption inside one file, on a volume size that
# is entirely ordinary for the SAN LUNs this filesystem targets.
#
# 16 TiB is also larger than ext4 can hold as a sparse file, which is
# why this needs a device-mapper zero+snapshot device rather than a
# loop-backed image.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

CEILING=17592186044416   # 2^32 blocks * 4096

log "checking the format ceiling on a volume bigger than it"
DEV="$(ct_huge_dev 17 mfs)"
if [ -z "$DEV" ]; then
    skip "device-mapper is unavailable; the >16 TiB case cannot be built here"
else
    MNT="$(ct_mnt mfs)"
    # Large Block Groups keep the Block Group table (one block each) and
    # the mkfs write volume small on a device this size.
    ct_mkfs "$DEV" -b 131072 -z 8 -J 0 -N 1024 -M 4 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"

    MAXB="$(sed -n 's/^max_file_size_bytes: //p' "$(ct_procdir "$DEV")/info" 2>/dev/null || true)"
    [ "$MAXB" = "$CEILING" ] &&
        pass "s_maxbytes is the format ceiling ($MAXB), not the volume's larger capacity" ||
        fail "s_maxbytes is $MAXB, expected the $CEILING format ceiling"

    # The assertion that actually matters: a write at the first
    # unaddressable logical block must be refused, not aliased.
    RES="$(python3 - "$MNT" <<'PY'
import os, sys, errno
fd = os.open(sys.argv[1] + "/alias", os.O_RDWR | os.O_CREAT, 0o644)
try:
    os.pwrite(fd, b"HIGH" * 1024, 4294967296 * 4096)
    os.fsync(fd)
    print("ALIASED:" + os.pread(fd, 16, 0).decode(errors="replace"))
except OSError as e:
    print("REFUSED:" + errno.errorcode.get(e.errno, str(e.errno)))
finally:
    os.close(fd)
PY
)"
    case "$RES" in
    REFUSED:EFBIG) pass "a write at logical block 2^32 is refused with EFBIG" ;;
    ALIASED:*) fail "a write at logical block 2^32 was accepted and aliased offset 0 (read back '${RES#ALIASED:}')" ;;
    *) fail "unexpected result from the boundary write: $RES" ;;
    esac

    # One block below the ceiling is legal and must still work -- the
    # clamp has to be exact, not merely conservative.
    RES2="$(python3 - "$MNT" <<'PY'
import os, sys, errno
fd = os.open(sys.argv[1] + "/edge", os.O_RDWR | os.O_CREAT, 0o644)
try:
    off = (4294967296 - 1) * 4096
    os.pwrite(fd, b"EDGE" * 1024, off)
    os.fsync(fd)
    print("OK" if os.pread(fd, 4, off) == b"EDGE" and os.pread(fd, 4, 0) == b"\0\0\0\0" else "WRONG")
except OSError as e:
    print("REFUSED:" + errno.errorcode.get(e.errno, str(e.errno)))
finally:
    os.close(fd)
PY
)"
    [ "$RES2" = "OK" ] &&
        pass "the last addressable block (2^32 - 1) is writable and does not alias" ||
        fail "the last addressable block: $RES2"

    # truncate(2) is a different VFS path (setattr_prepare), so assert it
    # separately rather than assuming the write check covers it.
    if truncate -s $((CEILING + 4096)) "$MNT/trunc" 2>/dev/null; then
        fail "truncate past the format ceiling was accepted"
    else
        pass "truncate past the format ceiling is refused"
    fi
    truncate -s "$CEILING" "$MNT/trunc" 2>/dev/null &&
        pass "truncate to exactly the ceiling is accepted" ||
        fail "truncate to exactly the ceiling was refused -- the clamp is off by one"

    ct_umount "$MNT"
fi

# ------------------------------------------------- the ordinary volume
log "checking a volume smaller than the ceiling still reports its own capacity"
SIMG="$(ct_image 1200 mfssmall)"
SDEV="$(ct_loop "$SIMG")"
SMNT="$(ct_mnt mfssmall)"
ct_mkfs "$SDEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$SDEV" "$SMNT"
SMAX="$(sed -n 's/^max_file_size_bytes: //p' "$(ct_procdir "$SDEV")/info" 2>/dev/null || echo 0)"
if [ "$SMAX" -gt 0 ] && [ "$SMAX" -lt "$CEILING" ]; then
    pass "a 1 GiB volume reports its own capacity ($SMAX), well under the ceiling"
else
    fail "a small volume reports max_file_size_bytes=$SMAX"
fi
# And the capacity cap is enforced: a file cannot exceed the volume.
if truncate -s $((SMAX + 4096)) "$SMNT/toobig" 2>/dev/null; then
    fail "a file larger than the whole volume's capacity was accepted"
else
    pass "a file larger than the volume's capacity is refused"
fi

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
