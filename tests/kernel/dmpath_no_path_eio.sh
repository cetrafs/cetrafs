#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAS over a multipath node with no path left fails with EIO, not "not supported"
#
# cetrafs_caw() over a dm node asks dmpath.c for a SCSI path. When none
# was left it fell out of a loop that could never iterate (C5) and
# returned -EOPNOTSUPP, the code for "this device has no COMPARE AND
# WRITE": the operation failed as EOPNOTSUPP, and creat(2) told the user
# the filesystem does not support creating files during a path outage
# (audit 2026-11-11 C6). It is a transport failure, nothing issued: EIO.
#
# The rig: dm-multipath over two LIO loopback paths, mounted with CAW;
# the next path lookup finds none (dmpath_no_path_once -- taking the
# SCSI devices offline fails the create's READS first, which is EIO for
# another reason), and a create is attempted.
#
#  1. the create fails with EIO.
#
# DISCRIMINATION (2026-11-11, caw.c before this fix): 1 fails with
# EOPNOTSUPP (ENOTSUP), three runs of three.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true

IMG="$(ct_image 600 dmnopath)"
DISKS="$(ct_lio_disks "$IMG" 2)" || { skip "no LIO loopback target here"; ct_exit; }
set -- $DISKS
[ $# -eq 2 ] || { fail "setup: expected two paths, got '$DISKS'"; ct_exit; }
D1="$1"; D2="$2"
NAME="ctdmnopath$$"
SECTORS="$(blockdev --getsz "$D1")"
M1="$(lsblk -dno MAJ:MIN "$D1" | tr -d ' ')"
M2="$(lsblk -dno MAJ:MIN "$D2" | tr -d ' ')"
dmsetup create "$NAME" --table "0 $SECTORS multipath 0 0 1 1 round-robin 0 2 1 $M1 1000 $M2 1000" ||
    { skip "dm-multipath is not available"; ct_exit; }
ct_track dm "$NAME"
DEV="/dev/mapper/$NAME"
udevadm settle 2>/dev/null || true
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
MNT="$(ct_mnt dmnopath)"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "dm path: .* sending COMPARE AND WRITE via" ||
    { fail "setup: the mount found no CAW path"; ct_exit; }
ct_param_set scrub 0
mkdir "$MNT/d"
sync

MARK="$(dmesg_mark)"
ct_param_set dmpath_no_path_once 1
E="$(python3 -I -c '
import errno, os, sys
try:
    os.close(os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)); print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$MNT/d/new" 2>&1 || true)"
[ "$(cat /sys/module/cetrafs/parameters/dmpath_no_path_once)" = N ] ||
    { ct_param_set dmpath_no_path_once 0; fail "setup: no CAW looked for a path"; ct_exit; }
[ "$E" != OK ] || { fail "setup: the create succeeded past a path lookup that found none"; ct_exit; }
[ "$E" = EIO ] && pass "1: the create failed with EIO" || fail "1: the create failed with $E"
ct_umount "$MNT"
ct_exit
