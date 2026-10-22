#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mixed-workload soak with a full fsck after every round (slow, opt-in)
#
#
# mount_test.sh proves specific behaviours; this hammers the structure
# with the operations that actually mutate it and then asks fsck whether
# anything broke. Since fsck gained its content and namespace passes it
# can name real damage -- cross-file block overlap, blocks in use but
# marked free, leaked blocks, unreachable inodes, nlink mismatches --
# so a round that comes back clean means something.
#
# Usage: sudo tests/soak.sh [rounds]   (default 20, ~5s each)
#
# Needs the module already loaded; it deliberately does NOT insmod, so
# it can be pointed at whatever build you want to exercise. Every step
# that could silently no-op (mkfs, mount) is checked -- a soak that
# passes because it never touched the filesystem is worse than no soak.
#
# Mixed-workload soak. The create-only soak proved creates; this exercises
# the paths that actually mutate structure -- unlink, rename, hardlink,
# truncate, hole-punch, xattrs, nested dirs, directory growth past the
# inline extents -- and fscks the unmounted result each round, so any
# structural damage is named rather than inferred.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG=${TMPDIR:-/tmp}/cetrafs-soak/mix.img; MNT=${TMPDIR:-/tmp}/cetrafs-soak/mixmnt
mkdir -p $MNT
if ! lsmod | grep -q '^cetrafs '; then echo "cetrafs module not loaded"; exit 2; fi
# A soak that found damage but still exited 0 would be worse than no soak
# (the "a test that cannot fail" trap). Count anomalous rounds and fail the
# whole run if any occurred -- while still finishing the remaining rounds, so
# one bad round does not hide a second and every failing image is captured.
ANOM=0
for r in $(seq 1 ${1:-20}); do
    rm -f $IMG; truncate -s 700M $IMG
    LOOP=$(losetup --find --show $IMG)
    if ! $ROOT/userspace/mkfs.cetra $LOOP -z 1 -b 512 -J 1 -M 4 -N 3000 -f >/tmp/mix_mkfs 2>&1; then
        echo "round $r: FATAL mkfs failed: $(tail -1 /tmp/mix_mkfs)"; losetup -d $LOOP; exit 2
    fi
    if ! mount -t cetrafs $LOOP $MNT 2>/dev/null || ! grep -q " $MNT cetrafs " /proc/self/mounts; then
        echo "round $r: FATAL mount failed"; losetup -d $LOOP; exit 2
    fi
    ERRS=0
    mkdir -p $MNT/a/b/c $MNT/z 2>/dev/null || ERRS=$((ERRS+1))
    # 1. grow a directory well past its inline extents
    for i in $(seq 1 120); do : > $MNT/a/f$i 2>/dev/null || ERRS=$((ERRS+1)); done
    # 2. files with data, then truncate and punch holes
    for i in $(seq 1 25); do
        dd if=/dev/zero of=$MNT/a/b/d$i bs=4096 count=$((i%9+1)) status=none 2>/dev/null || ERRS=$((ERRS+1))
    done
    for i in $(seq 1 10); do truncate -s $((i*1024)) $MNT/a/b/d$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 11 18); do
        fallocate -p -o 4096 -l 4096 $MNT/a/b/d$i 2>/dev/null || true
    done
    # 3. hardlinks, then drop some
    for i in $(seq 1 15); do ln $MNT/a/f$i $MNT/z/l$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 1 7); do rm -f $MNT/z/l$i 2>/dev/null || ERRS=$((ERRS+1)); done
    # 4. renames, within and across directories
    for i in $(seq 20 40); do mv $MNT/a/f$i $MNT/a/b/c/r$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 41 55); do mv $MNT/a/f$i $MNT/a/f$i.ren 2>/dev/null || ERRS=$((ERRS+1)); done
    # 5. xattrs
    for i in $(seq 1 12); do
        python3 -c "import os,sys; os.setxattr(sys.argv[1],'user.k%d'%$i,b'v'*$i)" $MNT/a/b/d$i 2>/dev/null || ERRS=$((ERRS+1))
    done
    # 6. delete a swathe, including a whole subtree
    for i in $(seq 56 120); do rm -f $MNT/a/f$i 2>/dev/null || ERRS=$((ERRS+1)); done
    rm -rf $MNT/a/b/c 2>/dev/null || ERRS=$((ERRS+1))
    sync; umount $MNT
    FSCK=$($ROOT/userspace/fsck.cetra $LOOP 2>&1 || true)
    if [ "$ERRS" != "0" ] || echo "$FSCK" | grep -q "problem"; then
        echo "round $r: ANOMALY op_errors=$ERRS"
        echo "$FSCK" | grep -E "ERR|WARN|problem" | head -6
        cp $IMG ${TMPDIR:-/tmp}/cetrafs-soak/mix-fail-$r.img 2>/dev/null
        ANOM=$((ANOM+1))
    else
        echo "round $r: clean  ($(echo "$FSCK" | grep -oP 'content: \K[^,]+'), $(echo "$FSCK" | grep -oP 'namespace: \K.*'))"
    fi
    losetup -d $LOOP
done
rm -f $IMG
if [ "$ANOM" != "0" ]; then
    echo "MIXDONE: $ANOM anomalous round(s) -- failing images saved as ${TMPDIR:-/tmp}/cetrafs-soak/mix-fail-*.img"
    exit 1
fi
echo MIXDONE
