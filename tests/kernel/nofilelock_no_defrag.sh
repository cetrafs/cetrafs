#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock disables defrag: no background pass takes a VM image being filled
#
# nofilelock disables defrag (docs/internal/BASICS.md), and the mount
# says so -- but from audit 2026-11-14 A-14 the background janitor ran
# there, and sparse images became eligible for it. A disk move fills a
# sparse image out of order with O_DIRECT, which is exactly what it
# picks up: pass after pass, each holding the file's lock, while the
# copy's writes waited behind them. On a FC array a 32 GiB move ran at
# 60 MB/s and ended near 1 MB/s, against 533 MB/s before (issue 13).
# cetrafs_sb_defrag_allowed() now refuses defrag under nofilelock, the
# janitor and the ioctl alike.
#
# nofilelock mount, auto_defrag on (the module default). One writer holds
# a sparse 64 MiB image open and fills it O_DIRECT, 1 MiB at a time, the
# odd MiB first and then the even ones, as an out-of-order copy leaves
# it fragmented; then it stays open a few seconds, as a VM keeps its
# disk:
#   setup: the image fragmented (the janitor's threshold was reached);
#   1. no defrag pass ran, and nothing was pinned;
#   2. defrag.cetra is refused, and procfs says defrag is not available;
#   3. the content is what was written; fsck clean.
#
# DISCRIMINATION: defrag_nofilelock=1 (the 0.10.x behaviour): the same
# fill runs defrag passes (1 fails).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_mode_own # mounts nofilelock itself
for k in defrag_nofilelock auto_defrag alloc_run_blocks; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set defrag_nofilelock 0
ct_param_set auto_defrag 1
ct_param_set alloc_run_blocks 0 # one extent per write, as a fragmented move leaves it
MNT="$(ct_mnt nfldf)"
DEFRAG="$ROOT/userspace/defrag.cetra"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# fill <file> <hold-seconds>: a sparse 64 MiB image filled O_DIRECT, odd
# MiB then even, held open after; prints the md5 of what it wrote
fill() { python3 -I - "$@" <<'PY'
import hashlib, mmap, os, sys, time
path, hold = sys.argv[1], float(sys.argv[2])
n = 64
fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_DIRECT, 0o644)
os.ftruncate(fd, n << 20)
buf = mmap.mmap(-1, 1 << 20)
data = {}
for i in list(range(1, n, 2)) + list(range(0, n, 2)):
    chunk = os.urandom(1 << 20)
    buf.seek(0); buf.write(chunk)
    os.pwrite(fd, buf, i << 20)
    data[i] = chunk
    if i % 8 == 0:
        os.fsync(fd)
os.fsync(fd)
time.sleep(hold)
os.close(fd)
print(hashlib.md5(b"".join(data[i] for i in range(n))).hexdigest())
PY
}

# <tag> <defrag_nofilelock 0|1> -> RES
round() {
    local dev proc p0 p1 sum got rc out ext
    dev="$(ct_dev 560 "nfldf$1")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    ct_track mnt "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "$2" >/sys/module/cetrafs/parameters/defrag_nofilelock
    p0="$(sed -n 's/^defrag_passes: //p' "$proc/info")"
    sum="$(fill "$MNT/vm.raw" 8)"
    p1="$(sed -n 's/^defrag_passes: //p' "$proc/info")"
    ext="$(filefrag "$MNT/vm.raw" | awk '{print $2}')"
    got="$(md5sum <"$MNT/vm.raw" | cut -d' ' -f1)"
    out="$("$DEFRAG" "$MNT/vm.raw" 2>&1)" && rc=0 || rc=$?
    RES="passes=$((p1 - p0)) pinned=$(sed -n 's/^defrag_pinned: //p' "$proc/info") extents=$ext"
    RES="$RES content=$([ "$got" = "$sum" ] && echo ok || echo BAD) manual_rc=$rc"
    RES="$RES avail=$(sed -n 's/^defrag_available: //p' "$proc/controls" | cut -d' ' -f1)"
    echo 0 >/sys/module/cetrafs/parameters/defrag_nofilelock
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (defrag_nofilelock=1): $C"
[ "$(get extents "$R")" -ge 8 ] && [ "$(get extents "$C")" -ge 2 ] ||
    { fail "setup: the image did not fragment ($R / $C)"; ct_exit; }
[ "$(get passes "$R")" = 0 ] && [ "$(get pinned "$R")" = 0 ] &&
    pass "1: no defrag pass took the image being filled ($R)" || fail "1: $R"
[ "$(get manual_rc "$R")" != 0 ] && [ "$(get avail "$R")" = no ] &&
    pass "2: defrag.cetra is refused, and procfs says defrag is not available" || fail "2: $R"
[ "$(get content "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: the image holds what was written; fsck clean" || fail "3: $R"
[ "$(get passes "$C")" -ge 1 ] &&
    pass "control: with defrag allowed under nofilelock, the same fill ran defrag passes ($C)" ||
    fail "control: $C -- the fill does not reach the janitor, so 1 proves nothing"
ct_exit
