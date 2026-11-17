#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation-bitmap write refused for space fails the boundary with ENOSPC, is kept, and lands later
#
# Any refused metadata write stopped the mount (audit 2026-11-14 A-4).
# An allocation-bitmap block of a group this node owns is the one held
# block a refusal can wait out: nothing names its new bits until it
# lands, and nothing gives the group up without writing it first. A
# DEFINITE refusal now fails the durability boundary (fsync) with
# ENOSPC, keeps the block held, and the next boundary retries it.
#
# With every bitmap write refused (bmap_write_nospc), a 1 MiB file is
# written and fsynced:
#   1. fsync fails with ENOSPC;
#   2. the mount runs on through heartbeat ticks (whose held flush is
#      refused too), refusals are counted;
#   3. the refusals stop: the next fsync succeeds;
#   4. after a remount the file reads back intact and fsck is clean.
#
# DISCRIMINATION: bmap_refusal_stops=1 (as before): the fsync stops the
# mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bmap_refusal_stops bmap_write_nospc; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt bnr)"
ct_track mnt "$MNT"
ct_param_set bmap_refusal_stops 0
ct_param_set bmap_write_nospc 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
SRC="$(ct_tmp bnr-src)"
head -c 1048576 /dev/urandom >"$SRC"
SUM="$(md5sum <"$SRC" | cut -d' ' -f1)"
# wr <path>: copy SRC in and fsync; "0" or the errno name
wr() { python3 -I -c '
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        os.write(fd, open(sys.argv[2], "rb").read()); os.fsync(fd)
    finally:
        try: os.close(fd)
        except OSError: pass
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1" "$2"; }
fs() { python3 -I -c '
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1"; }

# <tag> <stops 0|1> -> RES
round() {
    local img dev mark proc n first
    img="$(ct_image 560 "bnr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    : >"$MNT/a0"
    sync
    n="$(sed -n 's/^bmap_refusals: //p' "$proc/info")"
    echo "$2" >$P/bmap_refusal_stops
    mark="$(dmesg_mark)"
    echo 1000000 >$P/bmap_write_nospc
    first="$(wr "$MNT/g" "$SRC")"
    sleep 4 # heartbeat ticks, each with a refused held flush
    RES="first=$first refusals=$(($(sed -n 's/^bmap_refusals: //p' "$proc/info") - n))"
    RES="$RES alive=$(stat -c %s "$MNT/a0" 2>/dev/null || echo no)"
    echo 0 >$P/bmap_write_nospc
    echo 0 >$P/bmap_refusal_stops
    RES="$RES second=$(fs "$MNT/g")"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    if [ "$(get stopped "$RES")" = 0 ]; then
        ct_mount "$dev" "$MNT"
        [ "$(md5sum <"$MNT/g" | cut -d' ' -f1)" = "$SUM" ] && RES="$RES data=ok" || RES="$RES data=bad"
        ct_umount "$MNT"
        RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
    fi
}

round c 1
C="$RES"
log "control (a refusal stops): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get first "$R")" = ENOSPC ] && pass "1: with the bitmap refused, fsync failed ENOSPC" || fail "1: $R"
[ "$(get stopped "$R")" = 0 ] && [ "$(get alive "$R")" = 0 ] && [ "$(get refusals "$R")" -ge 2 ] &&
    pass "2: the mount ran on through the ticks; refusals counted" || fail "2: $R"
[ "$(get second "$R")" = 0 ] && pass "3: the refusals stopped: the next fsync landed" || fail "3: $R"
[ "$(get data "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "4: after a remount the file is intact and fsck is clean" || fail "4: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with refusals stopping, the mount stopped ($C)" ||
    fail "control: $C -- the injection does not reach the bitmap write"
ct_exit
