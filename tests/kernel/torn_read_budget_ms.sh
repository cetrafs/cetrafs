#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless reader that sees a peer's block write torn waits milliseconds for it, not microseconds
#
# Lookups, readdir, getxattr and the tree walks read 4 KiB tail-checksummed
# blocks with no lock, so a peer's write in flight can be seen torn, and
# they retry until it lands. The retry loops slept 100-400 us between
# five attempts -- about 2 ms in all, against a 4 KiB write that takes
# milliseconds on a real LUN -- and then answered -EIO (or counted the
# block corrupt). Every one of their comments said the budget spans a
# peer's write; the sleeps said otherwise (audit 2026-11-11 X1). Now
# 1, 2, 4 ... 128 ms, about a quarter of a second, paid only on a
# mismatch.
#
# tail_tear_ms makes every tail-checksummed read read torn for that long
# -- a peer's write that takes that long to land.
#
#  1. a 30 ms tear: getfattr waits it out and returns the value.
#  2. CONTROL, a 3 s tear (a block that never converges, as far as the
#     reader can tell): getfattr fails, and within the budget -- the
#     wait is bounded, not a hang.
#
# DISCRIMINATION (2026-11-11, the 100-400 us sleeps back): 1 fails -EIO.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/tail_tear_ms ] || { skip "tail_tear_ms is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "no python3"; ct_exit; }
gx() { python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.k").decode())' "$1"; }

IMG="$(ct_image 560 tearms)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt tearms)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
: >"$MNT/f"
python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", b"value1")' "$MNT/f"
gx "$MNT/f" >/dev/null 2>&1 || { fail "setup: the xattr does not read back"; ct_exit; }

# ------------------------------------------------------------------- 1
log "1: a peer's write that takes 30 ms to land"
echo 30 >/sys/module/cetrafs/parameters/tail_tear_ms
V="$(gx "$MNT/f" 2>/dev/null || echo FAILED)"
echo 0 >/sys/module/cetrafs/parameters/tail_tear_ms
[ "$V" = value1 ] && pass "1: the read waited the tear out and read the value" ||
    fail "1: the read gave up inside a 30 ms tear ($V) -- the budget is shorter than a peer's write"

# ------------------------------------------------------------------- 2
log "2: CONTROL -- a tear that outlasts the budget"
T0="$(date +%s%N)"
echo 3000 >/sys/module/cetrafs/parameters/tail_tear_ms
gx "$MNT/f" >/dev/null 2>&1 && R=ok || R=failed
T1="$(date +%s%N)"
echo 0 >/sys/module/cetrafs/parameters/tail_tear_ms
MS=$(((T1 - T0) / 1000000))
[ "$R" = failed ] && pass "2: a block that never converges still fails" || fail "2: read through a 3 s tear -- the injection does nothing"
[ "$MS" -lt 2500 ] && pass "2: and within the budget (${MS} ms)" || fail "2: took ${MS} ms -- the wait is not bounded by the budget"
ct_umount "$MNT"
ct_exit
