#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an xattr read checks the copy it parses, not only the buffer it copied
#
# The xattr reader validates the block in the shared buffer, then copies
# it under the buffer lock and parses the copy. Between the two, another
# reader's forced-fresh re-read of the same block can put a peer's
# half-written image in the buffer: the copy is then torn and was never
# checked (audit 2026-11-06 L3). The copy is now validated and a torn
# one retried.
#
# Staged with xattr_tear_copy_once, which flips the first value byte of
# the next private copy -- the image that re-read would have left. The
# read must still return the value as written.
#
# DISCRIMINATION: with the copy unchecked, the read returns the flipped
# byte.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_tear_copy_once ] || { skip "xattr_tear_copy_once is missing"; ct_exit; }

DEV="$(ct_dev 560 xattrcopy)"
MNT="$(ct_mnt xattrcopy)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/f"
get() { python3 -c 'import os,sys; sys.stdout.write(os.getxattr(sys.argv[1], "user.k").decode("latin-1"))' "$MNT/f"; }
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"value-as-written")' "$MNT/f"
[ "$(get)" = "value-as-written" ] || { fail "setup: the value does not read back untorn"; ct_umount "$MNT"; ct_exit; }
ct_param_set xattr_tear_copy_once 1
V="$(get 2>&1 || true)"
T="$(cat /sys/module/cetrafs/parameters/xattr_tear_copy_once)"
[ "$T" = N ] || { fail "setup: the read never took a copy to tear"; ct_umount "$MNT"; ct_exit; }
[ "$V" = "value-as-written" ] && pass "a torn copy was caught and re-read: the value is as written" ||
    fail "the read parsed a torn copy: got '$V'"
ct_umount "$MNT"
ct_exit
