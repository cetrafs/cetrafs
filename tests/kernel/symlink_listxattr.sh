#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# llistxattr() on a symlink lists the xattrs set on it
#
# Symlinks take xattrs (trusted.*, security.*), and getxattr finds them,
# but cetrafs_symlink_iops had no .listxattr: the VFS then lists only
# what the security module supplies, so a trusted.* name stored on the
# link was invisible to llistxattr() -- and to anything that copies a
# link's xattrs by listing them first (cp -a, rsync -X, tar --xattrs).
#
# DISCRIMINATION: without .listxattr on symlinks the name is not listed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 lnkxattr)"
MNT="$(ct_mnt lnkxattr)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo t >"$MNT/target"
ln -s target "$MNT/link"
RES="$(python3 - "$MNT/link" <<'PY'
import os, sys
p = sys.argv[1]
try:
    os.setxattr(p, "trusted.cetratest", b"v", follow_symlinks=False)
except OSError as e:
    print("set-failed", e.errno); sys.exit()
got = os.getxattr(p, "trusted.cetratest", follow_symlinks=False)
names = os.listxattr(p, follow_symlinks=False)
print("get=%s listed=%s" % (got.decode(), "trusted.cetratest" in names))
PY
)"
log "$RES"
case "$RES" in
set-failed*) fail "setup: the xattr could not be set on the symlink ($RES)" ;;
"get=v listed=True") pass "llistxattr lists the xattr set on the symlink" ;;
"get=v listed=False") fail "the symlink's xattr is readable but not listed" ;;
*) fail "unexpected: $RES" ;;
esac
ct_umount "$MNT"
ct_exit
