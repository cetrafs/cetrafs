#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fcntl and OFD byte-range locks are refused, never granted node-local
#
# cetrafs had no ->lock hook, so the VFS served fcntl(2) locks itself, in
# memory, on the calling node only: F_SETLK and F_OFD_SETLK succeeded,
# and a process on another node could take the same range a moment
# later. A lock that looks like protection and is none. qemu's image
# locking takes exactly these (docs/internal/QEMU-LOCKING.md). Now every
# such lock on a file or a directory fails with ENOLCK
# (cetrafs_posix_lock_refuse()); the cross-node lock is flock(2).
#
# DISCRIMINATION: posix_lock_local=1 gives the locks back to the VFS, as
# with no hook: the same calls then succeed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/posix_lock_local ] || { skip "posix_lock_local is missing"; ct_exit; }
DEV="$(ct_dev 560 fcntllk)"
MNT="$(ct_mnt fcntllk)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo data >"$MNT/f"
mkdir "$MNT/d"

# <path> -> one line per call: "<name> ok" or "<name> <errno name>"
probe() {
    python3 - "$1" <<'PY'
import errno, fcntl, os, struct, sys
F_OFD_GETLK, F_OFD_SETLK, F_OFD_SETLKW = 36, 37, 38
path = sys.argv[1]
isdir = os.path.isdir(path)
fd = os.open(path, os.O_RDONLY if isdir else os.O_RDWR)
def fl(t, start=100, ln=1):
    # struct flock on 64-bit Linux: short type, short whence, off_t start,
    # off_t len, pid_t pid (0 for OFD), padding
    return struct.pack("hhqqi4x", t, os.SEEK_SET, start, ln, 0)
calls = [("OFD_SETLK_RD", F_OFD_SETLK, fcntl.F_RDLCK), ("OFD_GETLK", F_OFD_GETLK, fcntl.F_WRLCK)]
if not isdir:
    calls += [("OFD_SETLK_WR", F_OFD_SETLK, fcntl.F_WRLCK), ("SETLK_WR", fcntl.F_SETLK, fcntl.F_WRLCK),
              ("GETLK", fcntl.F_GETLK, fcntl.F_WRLCK)]
for name, cmd, t in calls:
    try:
        fcntl.fcntl(fd, cmd, fl(t))
        print(name, "ok")
    except OSError as e:
        print(name, errno.errorcode.get(e.errno, str(e.errno)))
for name, cmd in (("OFD_UNLCK", F_OFD_SETLK), ("UNLCK", fcntl.F_SETLK)):
    try:
        fcntl.fcntl(fd, cmd, fl(fcntl.F_UNLCK))
    except OSError:
        pass
os.close(fd)
sys.stdout.flush()
PY
}

for p in f d; do
    out="$(probe "$MNT/$p")"
    [ -n "$out" ] || { fail "$p: setup: the probe printed nothing"; continue; }
    bad="$(grep -v ' ENOLCK$' <<<"$out" || true)"
    [ -z "$bad" ] && pass "$p: every fcntl/OFD lock call is refused with ENOLCK ($(wc -l <<<"$out") calls)" ||
        fail "$p: not refused: $(echo $bad)"
done

ct_param_set posix_lock_local 1
out="$(probe "$MNT/f")"
ct_param_set posix_lock_local 0
# (A classic SETLK on byte 100 then conflicts with the probe's own OFD
# lock there -- OFD and POSIX locks conflict -- so only the OFD sets are
# asserted granted.)
grep -q '^OFD_SETLK_RD ok$' <<<"$out" && grep -q '^OFD_SETLK_WR ok$' <<<"$out" &&
    pass "control: served node-local, the same locks are granted ($(echo $out))" ||
    fail "control: the node-local path did not grant them -- the suite cannot see the refusal: $(echo $out)"

# Nothing left behind: the file still opens, reads and closes, and the
# unmount (with the harness's busy-inode check) is clean.
[ "$(cat "$MNT/f")" = data ] && pass "the file reads normally after the probes" || fail "the file reads '$(cat "$MNT/f")'"
ct_umount "$MNT"
ct_exit
