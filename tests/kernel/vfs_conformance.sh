#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# three answers the VFS layer gives that cetrafs was not giving
#
# None of these is a corruption bug. Each is an answer userspace reads
# and acts on, and each was wrong or absent:
#
#   read(2) on a directory. POSIX names this case EISDIR, and the
#   generic helper returns exactly that; with no .read at all the VFS
#   answers EINVAL instead.
#
#   statfs's f_fsid. Left zero, every cetrafs mount identifies as the
#   same filesystem to anything that uses it -- NFS export among them.
#
#   FIEMAP_EXTENT_UNWRITTEN. A fallocate'd range has real blocks whose
#   CONTENT is not there yet; without the flag, filefrag and any backup
#   tool reading extents sees ordinary data and can copy whatever the
#   previous owner of those blocks left.
#
# Discrimination: each assertion fails against the code before its fix
# (EINVAL instead of EISDIR, f_fsid 0, no "unwritten" in filefrag).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 vfsconf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt vfsconf)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/adir"

RC=0
python3 - "$MNT" <<'PY' || RC=$?
import errno, os, sys
mnt = sys.argv[1]

# 1. read(2) on a directory
fd = os.open(mnt + "/adir", os.O_RDONLY)
try:
    os.read(fd, 4096)
    print("read on a directory SUCCEEDED")
    os.close(fd); os._exit(1)
except OSError as e:
    got = e.errno
finally:
    try: os.close(fd)
    except OSError: pass
print("read(2) on a directory -> %s" % errno.errorcode.get(got, got))
if got != errno.EISDIR:
    sys.stdout.flush(); os._exit(2)

# 2. statfs f_fsid
st = os.statvfs(mnt)
fsid = getattr(st, "f_fsid", 0)
print("statvfs f_fsid -> %s" % fsid)

# 3. a preallocated range must report as unwritten
import ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(mnt + "/prealloc", os.O_RDWR | os.O_CREAT, 0o644)
if libc.fallocate(f, 0, ctypes.c_long(0), ctypes.c_long(256 * 1024)) != 0:
    print("fallocate failed:", os.strerror(ctypes.get_errno()))
    sys.stdout.flush(); os._exit(3)
os.fsync(f); os.close(f)
sys.stdout.flush()
os._exit(0)
PY

case "$RC" in
  0) pass "read(2) on a directory returns EISDIR" ;;
  2) fail "read(2) on a directory does not return EISDIR" ;;
  3) fail "fallocate failed -- the unwritten assertion cannot be made" ;;
  *) fail "the probe failed (exit $RC)" ;;
esac

# f_fsid is reported by statfs(2); python's statvfs does not always
# surface it, so ask stat(1), which prints the kernel's value.
FSID="$(stat -f -c %i "$MNT" 2>/dev/null || echo 0)"
[ -n "$FSID" ] && [ "$FSID" != "0" ] && [ "$FSID" != "0 0" ] &&
    pass "statfs reports a nonzero f_fsid ($FSID)" ||
    fail "statfs reports f_fsid=$FSID -- every mount looks like the same filesystem"

command -v filefrag >/dev/null || { pass "filefrag absent: skipping the unwritten check"; ct_exit; }
OUT="$(filefrag -v "$MNT/prealloc" 2>/dev/null || true)"
echo "$OUT" | grep -qi "unwritten" &&
    pass "a preallocated extent is reported unwritten" ||
    fail "a preallocated extent reports as ordinary data: $(echo "$OUT" | sed -n '4p')"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

# 4. And the root inode has to BE a directory.
#
# d_make_root() on a regular file produces a root dentry the VFS walks
# into happily, and every path operation then runs against an object
# whose ops are not a directory's. The record comes off a shared
# device, and nothing on the mount path asked.
IPOKE="$(ct_helper inode_block_poke)"
"$IPOKE" "$IMG" setmode 1 0100644 >/dev/null 2>&1 ||
    fail "could not turn the root inode into a regular file"

MARK2="$(dmesg_mark)"
if timeout 60 mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "mounted a volume whose root inode is a regular file"
else
    pass "a root inode that is not a directory is refused"
fi
dmesg_since "$MARK2" | grep -q "root inode .* is not a directory" &&
    pass "and the refusal is the root-inode check, not something earlier" ||
    fail "refused, but not by the root-inode check -- this suite would prove nothing"

ct_exit
