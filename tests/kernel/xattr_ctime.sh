#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an xattr change moves the file's ctime, in core and in the record
#
# POSIX moves ctime on an attribute change, and incremental backups,
# rsync -X and tar --xattrs find changed files by it. setxattr and
# removexattr moved nothing: the record's ctime was never stamped, and
# a change that rewrote the xattr block in place touched no record at
# all.
#
# Each kind of change, a second apart: the first xattr (a new block),
# a second one and a replacement (in place), a removal that leaves one,
# the removal of the last (the block freed). After each the ctime must
# have moved, and after a remount -- read back from the record -- it
# must still be the moved value.
#
# DISCRIMINATION: without the stamping no step moves ctime.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 xactime)"
MNT="$(ct_mnt xactime)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
sync
ctime() { stat -c %Z "$MNT/f"; }
xa() { python3 -c '
import os, sys
p, op, name = sys.argv[1], sys.argv[2], sys.argv[3]
if op == "set": os.setxattr(p, name, sys.argv[4].encode())
else: os.removexattr(p, name)' "$MNT/f" "$@"; }

step() { # <label> <xa args...>
    local label="$1" c0 c1 c2
    shift
    c0="$(ctime)"
    sleep 1.1
    xa "$@"
    c1="$(ctime)"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    c2="$(ctime)"
    if [ "$c1" -gt "$c0" ] && [ "$c2" = "$c1" ]; then
        pass "$label: ctime moved ($c0 -> $c1) and the record kept it"
    else
        fail "$label: ctime $c0 -> $c1 in core, $c2 read back from the record"
    fi
}
step "first xattr (new block)" set user.a one
step "second xattr (in place)" set user.b two
step "replace a value (in place)" set user.a ONE
step "remove one of two (in place)" remove user.b
step "remove the last (block freed)" remove user.a
ct_umount "$MNT"
ct_exit
