#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CAW through a device-mapper node -- the multipath case (DESTRUCTIVE)
#
# In production this filesystem's LUN is reached through dm-multipath,
# and that used to disable clustering outright: cetrafs resolves the
# scsi_device it sends COMPARE AND WRITE to from the block device's
# parent, a dm node has no SCSI parent, so discovery reported class=none
# and fs.c's mount gate restricted the volume to a single mounter --
# even though the LUN and dm both handle CAW perfectly (userspace
# sg_compare_and_write through /dev/mapper/... succeeds, and a
# deliberate miscompare returns MISCOMPARE).
#
# dmpath.c resolves a SCSI path underneath the dm node and sends that one
# command there, while all ordinary I/O keeps going through dm so
# multipath failover still covers the data path. This proves the two
# halves that matter:
#
#   1. a 1:1 map -> CAW is found and actually used (CAS selftest passes);
#   2. a map that is NOT 1:1 -> REFUSED, falling back to no-CAW rather
#      than aiming COMPARE AND WRITE at the wrong blocks. Case 2 is the
#      one that would be silent, unbounded corruption if it regressed,
#      so it is built to defeat a size check alone: same total size,
#      halves swapped, so only the content guard can catch it.
#
# DESTRUCTIVE: it mkfs'es the device you name. Required argument, no
# default, and `make check` never invokes it.
#
#   ./tests/device/caw_dm_path.sh /dev/sda
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

DEV="${1:-}"
[ -b "$DEV" ] || { echo "usage: $0 <block-device>   (DESTRUCTIVE)"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 2; }
command -v dmsetup >/dev/null || { echo "dmsetup not available"; exit 2; }

MNT="$(mktemp -d /tmp/cetrafs-dmpath-XXXXXX)"
cleanup() {
    umount "$MNT" 2>/dev/null
    rmmod cetrafs 2>/dev/null
    dmsetup remove cawid 2>/dev/null
    dmsetup remove cawswap 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

SZ=$(blockdev --getsz "$DEV")
H=$((SZ / 2))
# Unload and WAIT for it: a module still loaded makes the next insmod
# fail, and a probe that silently produced nothing would read as a
# verdict of "no CAW" -- i.e. a pass turning into a false failure, or
# worse a false pass. Never let an empty verdict stand for one.
unload() {
    local tries=0
    while lsmod | grep -q '^cetrafs '; do
        rmmod cetrafs 2>/dev/null
        tries=$((tries + 1))
        [ "$tries" -gt 25 ] && return 1
        sleep 0.2
    done
    return 0
}

probe() { # <dm-name> -> prints the probe verdict line, or a reason
    unload || { echo "(cetrafs stayed loaded; probe impossible)"; return 1; }
    dmesg -C >/dev/null 2>&1
    insmod "$ROOT/kmod/cetrafs.ko" caw_probe="/dev/mapper/$1" 2>/dev/null ||
        { echo "(insmod failed)"; return 1; }
    dmesg | grep -i "caw probe" | tail -1
    rmmod cetrafs 2>/dev/null
}

echo "== a 1:1 map: CAW must be found through the dm node"
unload || { echo "cetrafs module is stuck loaded"; exit 2; }
dmsetup create cawid --table "0 $SZ linear $DEV 0" || { echo "cannot create dm map"; exit 2; }
"$ROOT/userspace/mkfs.cetra" /dev/mapper/cawid -f >/dev/null 2>&1 ||
    echo "  (mkfs declined; using the volume already on $DEV)"
V="$(probe cawid)"
case "$V" in
*"class=scsi"*"max_caw_blocks="[1-9]*) pass "1:1 map: atomic CAW discovered via a path ($V)" ;;
*) fail "1:1 map: CAW not found through dm -- $V" ;;
esac

echo "== and it is really USED, not just detected"
unload && insmod "$ROOT/kmod/cetrafs.ko" cas_selftest=1 2>/dev/null
dmesg -C >/dev/null 2>&1
if mount -t cetrafs /dev/mapper/cawid "$MNT" 2>/dev/null; then
    echo hello >"$MNT/probe-file" 2>/dev/null
    sync
    grep -q "available=yes" /proc/fs/cetrafs/*/properties 2>/dev/null &&
        pass "the mounted volume reports atomic CAW available" ||
        fail "mounted on dm but CAW reads unavailable"
    dmesg | grep -q "CAS selftest: PASSED" &&
        pass "a real compare-and-swap completed over the dm node" ||
        fail "the CAS selftest did not pass over dm: $(dmesg | grep -i selftest | tail -1)"
    [ "$(cat "$MNT/probe-file" 2>/dev/null)" = hello ] &&
        pass "ordinary file I/O works (data path still goes through dm)" ||
        fail "file I/O through the dm-mounted volume failed"
    umount "$MNT"
else
    fail "could not mount cetrafs on the dm node"
fi
rmmod cetrafs 2>/dev/null

echo "== a path failure must be ABSORBED, not surfaced"
# A second real path to one LUN cannot be fabricated here, so the
# transport error is injected (caw_fail_path_once). What matters is the
# behaviour around it: the failing path is dropped, a path is resolved
# again, and the SAME operation is retried -- so the caller never sees
# the error. Without the retry in cetrafs_caw(), this create fails EIO.
unload && insmod "$ROOT/kmod/cetrafs.ko" 2>/dev/null
dmesg -C >/dev/null 2>&1
if mount -t cetrafs /dev/mapper/cawid "$MNT" 2>/dev/null; then
    echo 1 >/sys/module/cetrafs/parameters/caw_fail_path_once 2>/dev/null
    if mkdir "$MNT/after-path-failure" 2>/dev/null; then
        pass "an operation succeeded across an injected path failure"
    else
        fail "the injected path failure surfaced to the caller (no retry on another path)"
    fi
    dmesg | grep -q "failed a COMPARE AND WRITE -- dropping it" &&
        pass "the failing path was dropped and rotation was logged" ||
        fail "no rotation logged: $(dmesg | grep -i 'dm path' | tail -1)"
    rmdir "$MNT/after-path-failure" 2>/dev/null
    umount "$MNT"
else
    fail "could not mount for the path-failure test"
fi
unload

echo "== THE SAFETY CASE: a map that is not 1:1 must be REFUSED"
# Same total size, halves swapped: dm LBA 0 is NOT device LBA 0, so a
# size comparison alone would wave this through.
dmsetup remove cawid
printf "0 $H linear $DEV $H\n$H $H linear $DEV 0\n" | dmsetup create cawswap ||
    { echo "cannot create the swapped map"; exit 2; }
V="$(probe cawswap)"
case "$V" in
*"max_caw_blocks=0"*|*"class=none"*) pass "non-1:1 map refused, fell back to no-CAW ($V)" ;;
*) fail "DANGER: CAW accepted on a map whose LBA 0 is not the device's LBA 0 -- $V" ;;
esac
dmsetup remove cawswap

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
