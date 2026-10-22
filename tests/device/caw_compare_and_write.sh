#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the atomic COMPARE AND WRITE primitive, on real hardware (DESTRUCTIVE)
# the half of the CAS coverage a loop device cannot give.
#
# tests/mount_test.sh runs against a loop-backed image, where
# cetrafs_cas_region() finds no atomic CAW and takes its plain
# read-fresh / mutate / write fallback. That fallback is correct there
# (fs.c's mount gate admits only one node to such a volume), but it
# means the compare-and-swap itself -- the primitive every claim path in
# this filesystem now rests on -- is never actually exercised by the
# regression suite. This script runs the same primitive against a real
# device that reports an atomic CAW length.
#
# DESTRUCTIVE: it mkfs'es the device you name. The device is a required
# argument with no default, deliberately -- nothing here should ever run
# by accident, and `make check` does not invoke it.
#
#   ./tests/caw_test.sh /dev/sda
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}
fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}
log() { echo "== $1"; }

DEV="${1:-}"
if [ -z "$DEV" ]; then
    echo "usage: $0 <device>   (DESTRUCTIVE -- the device is reformatted)" >&2
    exit 2
fi
if [ "$(id -u)" != "0" ]; then
    echo "must be run as root" >&2
    exit 2
fi
if [ ! -b "$DEV" ]; then
    echo "$DEV is not a block device" >&2
    exit 2
fi
if mount | grep -q "^$DEV "; then
    echo "$DEV is mounted -- refusing" >&2
    exit 2
fi

MNT="$(mktemp -d /tmp/cetrafs-caw-mnt-XXXXXX)"
MOUNTED=0
MODULE_LOADED=0

cleanup() {
    set +e
    [ "$MOUNTED" = "1" ] && umount "$MNT" 2>/dev/null
    # Never rmmod -f: forcing while a superblock is alive leaves a
    # dangling shrinker entry that Oopses on a later reclaim pass.
    [ "$MODULE_LOADED" = "1" ] && rmmod cetrafs 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

dmesg_mark() { dmesg | tail -1 | grep -oP '^\[\s*\K[0-9.]+'; }
dmesg_since() {
    local mark="$1"
    dmesg | awk -v mark="$mark" '
        match($0, /^\[[ ]*[0-9.]+\]/) {
            ts = substr($0, RSTART + 1, RLENGTH - 2)
            gsub(/ /, "", ts)
            if ((ts + 0) > (mark + 0)) print
        }'
}

modprobe libcrc32c 2>/dev/null
modprobe scsi_mod 2>/dev/null

log "checking that $DEV really reports an atomic CAW length"
# The whole point of this script. If the device has no CAW there is
# nothing here the loop suite does not already cover, and asserting
# anything about atomicity would be asserting about the fallback.
CAW_MARK="$(dmesg_mark)"
insmod "$ROOT/kmod/cetrafs.ko" caw_probe="$DEV" || {
    echo "insmod failed" >&2
    exit 2
}
MODULE_LOADED=1
PROBE="$(dmesg_since "$CAW_MARK" | grep 'caw probe:' | head -1)"
rmmod cetrafs
MODULE_LOADED=0

echo "  $PROBE"
case "$PROBE" in
    *"atomic CAW available"*) pass "caw: $DEV reports an atomic CAW length" ;;
    *)
        fail "caw: $DEV reports no atomic CAW -- this script has nothing to test on it"
        echo "$FAIL check(s) failed"
        exit 1
        ;;
esac

log "formatting $DEV"
"$ROOT/userspace/mkfs.cetra" "$DEV" -f >/dev/null || {
    fail "mkfs failed"
    exit 1
}
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null || {
    fail "fsck rejected a freshly formatted volume"
    exit 1
}
pass "mkfs + fsck on $DEV"

# cas_stress races N threads on one record; cas_selftest does the
# single-threaded round trip. Both run at mount, before the heartbeat
# starts rewriting the row block they use for scratch.
THREADS=8
# 200, not the module default of 50. Measured on the real LUN at ~32 ms
# per compare-and-swap (400 increments took 13 s), so 1600 costs under a
# minute -- cheap next to the mkfs and two fscks of a 5 GiB device this
# run already pays, and a far better sample of the interleavings than
# 400. The loop-device suite does 3200 in about a second; the wire is
# what makes this one expensive, not the CPU.
ITERS=200
log "mounting with cas_selftest + cas_stress ($THREADS threads x $ITERS increments)"
RUN_MARK="$(dmesg_mark)"
insmod "$ROOT/kmod/cetrafs.ko" cas_selftest=1 cas_stress="$THREADS" cas_stress_iters="$ITERS" || {
    fail "insmod failed"
    exit 1
}
MODULE_LOADED=1
mount -t cetrafs "$DEV" "$MNT" || {
    fail "mount failed"
    dmesg_since "$RUN_MARK" | tail -20
    exit 1
}
MOUNTED=1

# The rule this project keeps relearning: prove we are really on cetrafs
# before asserting anything, or every assertion below is about the host
# filesystem.
FSTYPE="$(stat -f -c %T "$MNT" 2>/dev/null)"
if mount | grep -q " $MNT type cetrafs "; then
    pass "mount: really on a cetrafs mount (not the host fs)"
else
    fail "mount: $MNT is not a cetrafs mount (stat says '$FSTYPE') -- aborting"
    exit 1
fi

# The stress runs from fill_super, so leaving the param set makes every
# LATER mount in this script pay for it again -- on this LUN that is a
# wasted minute per remount, for a result already recorded.
[ -w /sys/module/cetrafs/parameters/cas_stress ] && echo 0 >/sys/module/cetrafs/parameters/cas_stress

RUN_LOG="$(dmesg_since "$RUN_MARK")"

echo "$RUN_LOG" | grep -q "CAS selftest: starting .* via the atomic CAW path" &&
    pass "cas: the self-test took the atomic CAW path (not the fallback)" ||
    fail "cas: the self-test did not report taking the CAW path"

echo "$RUN_LOG" | grep -q "CAS selftest: PASSED" &&
    pass "cas: single-threaded CAS round trip" ||
    fail "cas: self-test did not pass: $(echo "$RUN_LOG" | grep 'CAS selftest')"

# The assertion this whole script exists for. Every increment that
# returned success must be present in the final counter: a CAS that
# overwrote a value it never compared against would show up here as a
# lost update, and cannot on a device that MISCOMPAREs.
STRESS="$(echo "$RUN_LOG" | grep 'CAS stress: .* successful increments')"
echo "  $STRESS"
echo "$RUN_LOG" | grep -q "CAS stress: PASSED -- no lost updates" &&
    pass "cas: $THREADS threads racing on one record lost no updates" ||
    fail "cas: concurrent CAS lost updates: $STRESS"

# "No lost updates" is only evidence if the threads actually raced. Each
# CAW costs ~32 ms on this LUN, so eight threads could in principle take
# turns and never collide once -- and this run would be just as green
# while exercising nothing the primitive exists for. A MISCOMPARE is the
# device telling us a race was genuinely lost and retried, so a nonzero
# count is the proof that the atomic path was contended.
MISC="$(echo "$STRESS" | grep -oP '\K[0-9]+(?= miscompares)')"
if [ -z "$MISC" ]; then
    fail "cas: the stress line reports no miscompare count -- cannot tell whether the threads raced at all"
elif [ "$MISC" -gt 0 ]; then
    pass "cas: the threads genuinely contended ($MISC MISCOMPAREs retried against a fresh image)"
else
    fail "cas: zero MISCOMPAREs -- the threads never actually collided, so 'no lost updates' proves nothing here"
fi

# A stress run that errored on every attempt would also "lose nothing".
OKC="$(echo "$STRESS" | grep -oP '\K[0-9]+(?= successful)')"
WANT=$((THREADS * ITERS))
[ -n "$OKC" ] && [ "$OKC" = "$WANT" ] &&
    pass "cas: all $WANT increments succeeded (none silently errored out)" ||
    fail "cas: only $OKC of $WANT increments succeeded -- the counter check proves less than it looks"

log "ordinary filesystem operations on the real device"
mkdir -p "$MNT/d1"
for i in $(seq 1 40); do
    echo "content-$i" > "$MNT/d1/f$i"
done
sync
COUNT="$(ls "$MNT/d1" | wc -l)"
[ "$COUNT" = "40" ] && pass "fs: 40 files created and listed back" ||
    fail "fs: expected 40 files, found $COUNT"

BAD=0
for i in $(seq 1 40); do
    [ "$(cat "$MNT/d1/f$i")" = "content-$i" ] || BAD=$((BAD + 1))
done
[ "$BAD" = "0" ] && pass "fs: all 40 files read back correctly" ||
    fail "fs: $BAD of 40 files had wrong content"

umount "$MNT"
MOUNTED=0
mount -t cetrafs "$DEV" "$MNT"
MOUNTED=1
COUNT2="$(ls "$MNT/d1" | wc -l)"
[ "$COUNT2" = "40" ] && pass "fs: all 40 files survived a remount" ||
    fail "fs: $COUNT2 of 40 files survived the remount"

rm -rf "$MNT/d1"
sync
umount "$MNT"
MOUNTED=0

"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null &&
    pass "fsck: clean after the run" ||
    fail "fsck: reported problems after the run"

rmmod cetrafs
MODULE_LOADED=0

if dmesg_since "$RUN_MARK" | grep -qiE "BUG:|Oops|general protection|call trace"; then
    fail "kernel: an Oops/BUG appeared in dmesg during this run"
    dmesg_since "$RUN_MARK" | grep -iE -A5 "BUG:|Oops|call trace" | head -20
else
    pass "kernel: no Oops or BUG in dmesg during this run"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
echo "ALL CHECKS PASSED"
