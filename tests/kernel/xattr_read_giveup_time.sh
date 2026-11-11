#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an xattr block that never reads back whole gives up without a last, useless sleep
#
# cetrafs_xattr_read_block() retries a torn copy with a growing backoff.
# It also slept after the LAST attempt, so a block that never converged
# cost 128 ms more before "giving up" -- for nothing, no read followed.
# Every copy is torn here (xattr_tear_copies): the read must fail, and
# within the backoffs that precede a retry (1+2+...+128 = 255 ms), well
# short of the 383 ms the extra sleep made it.
#
# DISCRIMINATION (2026-11-11, xattr.c before this fix): takes ~390 ms.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_tear_copies ] || { skip "xattr_tear_copies is missing"; ct_exit; }

DEV="$(ct_dev 560 xgiveup)"
MNT="$(ct_mnt xgiveup)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/f"
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"v")' "$MNT/f"
best=999999
for _ in 1 2 3; do
    ct_param_set xattr_tear_copies 100
    out="$(python3 -c '
import os, sys, time
t = time.monotonic()
try:
    os.getxattr(sys.argv[1], "user.k"); r = "read"
except OSError as e:
    r = e.strerror
print("%s %d" % (r, (time.monotonic() - t) * 1000))' "$MNT/f")"
    left="$(cat /sys/module/cetrafs/parameters/xattr_tear_copies)"
    ct_param_set xattr_tear_copies 0
    [ "$left" -lt 100 ] || { fail "setup: no copy was torn"; break; }
    case "$out" in read*) fail "setup: the read succeeded through torn copies ($out)"; break ;; esac
    ms="${out##* }"
    [ "$ms" -lt "$best" ] && best=$ms
done
[ "$best" -lt 330 ] && pass "gave up after $best ms (fastest of 3): no sleep after the last attempt" ||
    fail "giving up took $best ms (fastest of 3): it still sleeps after the last attempt"
ct_umount "$MNT"
ct_exit
