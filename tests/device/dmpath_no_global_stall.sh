#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a slow path resolution on one volume must not stall every other one (DESTRUCTIVE)
#
# cetrafs caches, per stacked device, the SCSI path it sends COMPARE AND
# WRITE down. Resolving one opens a block device and issues a READ --
# both of which, on a flapping path or one mid-ALUA-transition, block
# for as long as the SCSI layer is willing to wait.
#
# That resolution used to run holding the cache's single global mutex.
# Every CAW on every volume this node has mounted queues behind that
# mutex, and so does the heartbeat's lease renewal -- so one bad cable
# on one LUN stops a node renewing its lease and a peer fences it. The
# volume whose path is being resolved has to wait, because it has no
# path; nothing else should.
#
# A dm-linear volume over each of TWO devices, one forced to re-resolve
# with the resolution artificially slowed, and an operation on the OTHER
# one timed. It must finish long before the resolution does.
#
# Two devices, not two slices of one: dmpath refuses a map that is not
# 1:1 with its SCSI device (aiming COMPARE AND WRITE at the wrong blocks
# is the one failure that would be silent), so halves of a single LUN
# both come back class=none and there is nothing to stall.
#
# Needs real SCSI: dmpath.c only runs when a dm node sits over a SCSI
# device, which a loop device never is -- so this cannot live in
# tests/kernel/. A LIO/targetcli LUN over iSCSI is enough; it does not
# have to be a SAN.
#
# DESTRUCTIVE: it mkfs'es the device you name. Required argument, no
# default, and `make check` never invokes it.
#
#   ./tests/device/dmpath_no_global_stall.sh /dev/sda /dev/sdb
#
# Discrimination: hold cetrafs_dmpath_mutex across
# cetrafs_dmpath_resolve() again and the timed operation takes the whole
# delay instead of milliseconds.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

DEV_A="${1:-}"
DEV_B="${2:-}"
[ -b "$DEV_A" ] && [ -b "$DEV_B" ] ||
    { echo "usage: $0 <block-device> <other-block-device>   (DESTRUCTIVE, both)"; exit 2; }
[ "$DEV_A" != "$DEV_B" ] || { echo "the two devices must be different"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 2; }
command -v dmsetup >/dev/null || { echo "dmsetup not available"; exit 2; }

SECT_A="$(blockdev --getsz "$DEV_A")"
SECT_B="$(blockdev --getsz "$DEV_B")"
# ~560 MiB is the smallest volume this mkfs geometry takes.
for pair in "$DEV_A:$SECT_A" "$DEV_B:$SECT_B"; do
    if [ "$(( ${pair#*:} * 512 / 1048576 ))" -lt 600 ]; then
        echo "SKIP: ${pair%%:*} is smaller than 600 MiB"
        exit 0
    fi
done

MNT_A="$(mktemp -d /tmp/cetrafs-stallA-XXXXXX)"
MNT_B="$(mktemp -d /tmp/cetrafs-stallB-XXXXXX)"
cleanup() {
    [ -w /sys/module/cetrafs/parameters/dmpath_resolve_delay_ms ] &&
        echo 0 > /sys/module/cetrafs/parameters/dmpath_resolve_delay_ms
    umount "$MNT_A" 2>/dev/null
    umount "$MNT_B" 2>/dev/null
    rmmod cetrafs 2>/dev/null
    dmsetup remove stallA 2>/dev/null
    dmsetup remove stallB 2>/dev/null
    rmdir "$MNT_A" "$MNT_B" 2>/dev/null
}
trap cleanup EXIT

# 1:1 maps, which is the only shape dmpath will resolve a path for.
dmsetup create stallA --table "0 $SECT_A linear $DEV_A 0" || { echo "dmsetup stallA failed"; exit 2; }
dmsetup create stallB --table "0 $SECT_B linear $DEV_B 0" || { echo "dmsetup stallB failed"; exit 2; }

"$ROOT/userspace/mkfs.cetra" /dev/mapper/stallA -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 ||
    { echo "mkfs on stallA failed"; exit 2; }
"$ROOT/userspace/mkfs.cetra" /dev/mapper/stallB -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 ||
    { echo "mkfs on stallB failed"; exit 2; }

rmmod cetrafs 2>/dev/null
MARK="dmpath-stall-$$"
echo "$MARK" > /dev/kmsg                      # only count resolutions from THIS run
insmod "$ROOT/kmod/cetrafs.ko" || { echo "insmod failed"; exit 2; }
mount -t cetrafs /dev/mapper/stallA "$MNT_A" || { echo "mount A failed"; exit 2; }
mount -t cetrafs /dev/mapper/stallB "$MNT_B" || { echo "mount B failed"; exit 2; }

# Both must really be going through a resolved SCSI path, or there is
# nothing to stall and the timing below means nothing.
PATHS="$(dmesg | sed -n "/$MARK/,\$p" | grep -c 'sending COMPARE AND WRITE via')"
[ "$PATHS" -ge 2 ] ||
    { echo "SKIP: only $PATHS dm path resolution(s) logged -- this device is not reached through one"; exit 0; }

mkdir "$MNT_A/warm" "$MNT_B/warm"      # both slots now cached

DELAY_MS=4000
echo "$DELAY_MS" > /sys/module/cetrafs/parameters/dmpath_resolve_delay_ms

# Make A's next CAW report a transport error: dmpath drops the path it
# used, so the one after that has to resolve -- slowly.
echo 1 > /sys/module/cetrafs/parameters/caw_fail_path_once
mkdir "$MNT_A/drop" 2>/dev/null                       # consumes the injected failure
( mkdir "$MNT_A/slow" 2>/dev/null ) &                 # this one waits for the resolution
SLOW_PID=$!
sleep 0.3                                             # let it get into the resolve

START="$(date +%s%N)"
mkdir "$MNT_B/quick" 2>/dev/null
ELAPSED_MS=$(( ($(date +%s%N) - START) / 1000000 ))

wait "$SLOW_PID" 2>/dev/null
echo 0 > /sys/module/cetrafs/parameters/dmpath_resolve_delay_ms

echo "== an operation on the other volume took ${ELAPSED_MS}ms while a ${DELAY_MS}ms resolution was in flight"
if [ "$ELAPSED_MS" -lt $((DELAY_MS / 2)) ]; then
    pass "a path resolution on one volume does not hold up another"
else
    fail "the other volume waited ${ELAPSED_MS}ms -- the resolution is holding the cache mutex, and the heartbeat queues there too"
fi

[ -d "$MNT_B/quick" ] && pass "and the operation actually happened" ||
    fail "the operation on the other volume did not complete"

umount "$MNT_A"; umount "$MNT_B"
"$ROOT/userspace/fsck.cetra" /dev/mapper/stallA >/dev/null 2>&1 &&
    "$ROOT/userspace/fsck.cetra" /dev/mapper/stallB >/dev/null 2>&1 &&
    pass "both volumes are clean" || fail "fsck reported faults"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
