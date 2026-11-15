#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a setxattr whose block reached the device reports success even if its change-time stamp then fails
#
# An xattr change to an existing block writes the block -- at which
# point every reader sees the new value -- and then stamps the record's
# ctime. A failed stamp returned the error: the caller was told the
# attribute was not set while every reader read it set (audit 2026-11-11
# X5). The stamp cannot go first (a peer refreshing its security label on
# the ctime move would read the old block), so the change stands, the
# call succeeds, and the missed stamp is said.
#
#  1. the stamp fails: setxattr returns success, the new value reads
#     back, and the kernel says the stamp was missed.
#  2. CONTROL: no failure -- no such message.
#
# DISCRIMINATION (2026-11-11, the stamp's error returned): 1's setxattr
# fails though the value changed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_ctime_cas_fail ] || { skip "xattr_ctime_cas_fail is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "no python3"; ct_exit; }

IMG="$(ct_image 560 xctime)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xctime)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# A directory: a regular file's block is replaced and its pointer and
# ctime published in one swap (audit 2026-11-15 BM N-74); the in-place
# write followed by a ctime stamp is a directory's.
mkdir "$MNT/f"
sx() { python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", sys.argv[2].encode())' "$MNT/f" "$1"; }
gx() { python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.k").decode())' "$MNT/f"; }
sx one # the block exists: the next set rewrites it in place

log "2: CONTROL -- an ordinary change"
MARK="$(dmesg_mark)"
sx two && [ "$(gx)" = two ] && pass "2: set and read back" || fail "2: an ordinary setxattr failed"
dmesg_since "$MARK" | grep -q "change time could not be stamped" && fail "2: the warning fired with nothing failing" ||
    pass "2: no warning"

log "1: the ctime stamp fails after the block is written"
MARK="$(dmesg_mark)"
ct_param_set xattr_ctime_cas_fail 1
sx three && R=0 || R=$?
ct_param_set xattr_ctime_cas_fail 0
[ "$(gx)" = three ] || { fail "setup: the block write did not land -- nothing to report on"; ct_exit; }
[ "$R" = 0 ] && pass "1: setxattr reported success -- the value it set is what every reader sees" ||
    fail "1: setxattr reported failure, yet the new value reads back"
dmesg_since "$MARK" | grep -q "the attribute is set, but its change time could not be stamped" &&
    pass "1: and the missed stamp was said" || fail "1: the missed stamp went unsaid"
ct_umount "$MNT"
ct_exit
