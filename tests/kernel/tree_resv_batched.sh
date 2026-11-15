#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the tree reserve's blocks are written together, not one waited write each
#
# A convert that needs room reserves its tree blocks first, and since a
# full thin pool must refuse it before anything is edited, writes each
# reserved block when it reserves it. Four blocks, each written and
# waited for before the next: ~150 ms per such convert on a SAN (F-5).
# They are now written under one plug and waited for together.
#
# The volume sits on dm-delay (40 ms per write) -- a loop device costs
# nothing per write. A fresh file, one preallocated extent: the second
# O_DIRECT write into its middle is the first convert that needs room,
# and its latency is timed.
#   1. it is at least two delays faster than with the writes serial;
#   2. both writes read back after a remount; fsck clean.
#
# DISCRIMINATION: resv_provision_serial=1: the same write is slower by
# about three delays -- 1 fails on the comparison.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/resv_provision_serial ] || { skip "resv_provision_serial is missing"; ct_exit; }
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_delay 2>/dev/null || true
grep -q '^delay' <(dmsetup targets) || { skip "no dm delay target"; ct_exit; }
MNT="$(ct_mnt trb)"
ct_track mnt "$MNT"
ct_param_set resv_provision_serial 0
ct_param_set auto_defrag 0
DELAY_MS=40

# <serial 0|1> -> "ms=<latency of the convert that needs room> ok=<0|1> fsck=<clean|ERR>"
round() {
    local loop dm dev ms ok=0 out
    loop="$(ct_loop "$(ct_image 560 "trb$1")")"
    dm="cetra-trb$$-$1"
    dmsetup create "$dm" --table "0 $(blockdev --getsz "$loop") delay $loop 0 0 $loop 0 $DELAY_MS"
    ct_track dm "$dm"
    dev="/dev/mapper/$dm"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    fallocate -l $((64 * 4096)) "$MNT/f"
    echo "$1" >/sys/module/cetrafs/parameters/resv_provision_serial
    ms="$(python3 -I - "$MNT/f" <<'PY'
import os, sys, mmap, time
def w(fd, b):
    m = mmap.mmap(-1, 4096); m.write(((b'blk%08d' % b) * 512)[:4096])
    t = time.monotonic(); os.pwrite(fd, m, b * 4096); return time.monotonic() - t
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
w(fd, 1)
print(int(w(fd, 3) * 1000))
os.close(fd)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/resv_provision_serial
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
ok = all(d[b*4096:(b+1)*4096] == (((b'blk%08d' % b) * 512)[:4096] if b in (1, 3) else bytes(4096)) for b in range(64))
sys.exit(0 if ok else 1)" "$MNT/f" && ok=1
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    dmsetup remove "$dm"
    echo "ms=$ms ok=$ok fsck=$out"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "batched: $R"
C="$(round 1)"
log "control (serial): $C"
[ "$(($(get ms "$C") - $(get ms "$R")))" -ge $((DELAY_MS * 2)) ] &&
    pass "1: the convert took $(get ms "$R") ms, $(get ms "$C") ms with the reserve written serially" ||
    fail "1: batched $(get ms "$R") ms against serial $(get ms "$C") ms -- not two delays apart"
[ "$(get ok "$R")" = 1 ] && [ "$(get fsck "$R")" = clean ] && pass "2: both writes read back after a remount; fsck clean" ||
    fail "2: $R"
ct_exit
