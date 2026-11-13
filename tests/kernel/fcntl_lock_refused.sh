#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fcntl and OFD byte-range locks are refused on a file-lock mount, granted node-local under nofilelock or localposixlocks
#
# cetrafs had no ->lock hook, so the VFS served fcntl(2) locks itself, in
# memory, on the calling node only: F_SETLK and F_OFD_SETLK succeeded,
# and a process on another node could take the same range a moment
# later. A lock that looks like protection and is none. qemu's image
# locking takes exactly these (docs/internal/QEMU-LOCKING.md). On a mount
# with the file lock on, every such lock on a file or a directory now
# fails with ENOLCK (cetrafs_posix_lock_refuse()); the cross-node lock is
# flock(2).
#
# Two mounts grant them node-local instead, so a stock qemu (locking on)
# still opens its images: nofilelock, where cross-node exclusion is the
# layer above's job anyway, and localposixlocks, the operator's opt-in on
# a file-lock mount. The option is mount-time only: a remount asking for
# it changes nothing.
#
# DISCRIMINATION: the default mount and the two granting ones run the
# same probe; each must come out the other way from its neighbour.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_mode_own # this suite mounts each mode itself
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

# <label>: every call refused, on the file and the directory
refused() {
    local p out bad
    for p in f d; do
        out="$(probe "$MNT/$p")"
        [ -n "$out" ] || { fail "$1 $p: setup: the probe printed nothing"; continue; }
        bad="$(grep -v ' ENOLCK$' <<<"$out" || true)"
        [ -z "$bad" ] && pass "$1 $p: every fcntl/OFD lock call is refused with ENOLCK ($(wc -l <<<"$out") calls)" ||
            fail "$1 $p: not refused: $(echo $bad)"
    done
}
# <label>: the locks granted node-local. (A classic SETLK on byte 100
# then conflicts with the probe's own OFD lock there -- OFD and POSIX
# locks conflict -- so only the OFD sets are asserted granted; on the
# directory only the read lock exists.)
granted() {
    local out
    out="$(probe "$MNT/f")"
    grep -q '^OFD_SETLK_RD ok$' <<<"$out" && grep -q '^OFD_SETLK_WR ok$' <<<"$out" &&
        pass "$1 f: the locks are granted node-local ($(echo $out))" ||
        fail "$1 f: not granted: $(echo $out)"
    out="$(probe "$MNT/d")"
    grep -q '^OFD_SETLK_RD ok$' <<<"$out" && pass "$1 d: granted ($(echo $out))" || fail "$1 d: not granted: $(echo $out)"
    [ "$(cat "$MNT/f")" = data ] && pass "$1: the file reads normally after the probes" || fail "$1: the file reads '$(cat "$MNT/f")'"
}
mopts() { grep " $MNT " /proc/mounts | awk '{print $4}'; }

# 1. The default mount refuses -- and a remount asking for the option
#    does not change that.
refused "1 default"
case ",$(mopts)," in *,localposixlocks,*) fail "1: /proc/mounts shows localposixlocks on a default mount" ;; *) pass "1: /proc/mounts has no localposixlocks" ;; esac
mount -o remount,localposixlocks "$MNT" || fail "1: the remount itself failed"
refused "1 after remount,localposixlocks"
case ",$(mopts)," in *,localposixlocks,*) fail "1: the remount put localposixlocks in force" ;; *) pass "1: the remount left it off (mount-time only)" ;; esac
ct_umount "$MNT"

# 2. localposixlocks on a file-lock mount: granted, and shown.
mount -t cetrafs -o localposixlocks "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q '^file_lock: on' "$(ct_procdir "$DEV")/info" && pass "2: the file lock is on" || fail "2: setup: the file lock is not on"
case ",$(mopts)," in *,localposixlocks,*) pass "2: /proc/mounts shows localposixlocks" ;; *) fail "2: /proc/mounts lacks localposixlocks: $(mopts)" ;; esac
granted "2 localposixlocks"
ct_umount "$MNT"

# 3. nofilelock: granted without asking.
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q '^file_lock: off' "$(ct_procdir "$DEV")/info" && pass "3: the file lock is off" || fail "3: setup: the file lock is not off"
granted "3 nofilelock"
ct_umount "$MNT"

# 4. And back to the default: refused again -- nothing carried over.
ct_mount "$DEV" "$MNT"
refused "4 default again"
ct_umount "$MNT"
ct_exit
