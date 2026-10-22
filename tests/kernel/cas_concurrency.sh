#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the compare-and-swap is atomic against concurrent LOCAL threads
#
# cetrafs_cas_region() has two backends: an atomic SCSI COMPARE AND WRITE
# where the device offers one, and a plain read / mutate / write where it
# does not. The no-CAW path is correct against PEERS by construction --
# fs.c's mount gate admits only one node to such a volume -- but that
# says nothing about the threads of the one node that IS mounted.
#
# It said nothing, and nothing covered it: the fallback was only ever
# exercised single-threaded (cas_selftest at mount), and the one
# concurrent exercise (cas_stress) reported its result as a diagnostic
# instead of asserting it, on the stated grounds that every production
# caller was serialised by some higher lock. Four of the eight callers
# were not -- including the global inode bitmap, which fs.c explicitly
# exempted from alloc_mutex BECAUSE the CAS was believed atomic.
#
# The cost was two files sharing one inode number. This suite asserts
# both layers: the primitive must lose no updates, and concurrent
# creates in DIFFERENT directories (so the parent's namespace lock
# cannot serialise them) must get distinct inodes.
#
# Reverting the fix fails assertions 1 and 3 here (measured: 96 of 3200
# increments lost, 15 duplicate inode numbers across 2400 files).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PARALLEL_CREATE="$(ct_helper parallel_create)"

CAS_STRESS_PARAM=/sys/module/cetrafs/parameters/cas_stress
CAS_ITERS_PARAM=/sys/module/cetrafs/parameters/cas_stress_iters
STRESS_THREADS=8
STRESS_ITERS=400

# cas_stress runs from fill_super, so the params have to be set before
# the mount that is meant to run it, and put back afterwards -- they are
# module-global and would otherwise make every later mount pay for it.
restore_stress() {
    [ -w "$CAS_STRESS_PARAM" ] && echo 0 >"$CAS_STRESS_PARAM"
    return 0
}

DEV="$(ct_dev 560 cas)"
MNT="$(ct_mnt cas)"
# -N 4096: the probe below creates thousands of files, and running out
# of inodes would end the test early with everything still passing.
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 4096 -f >/dev/null

log "checking the CAS primitive loses no updates under concurrent local threads"
ct_param_set cas_stress "$STRESS_THREADS"
ct_param_set cas_stress_iters "$STRESS_ITERS"
STRESS_MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
restore_stress
require_cetrafs_mount "$MNT"

STRESS_LINE="$(dmesg_since "$STRESS_MARK" | grep -o 'CAS stress: [0-9]* threads, .*' | head -1)"
if [ -z "$STRESS_LINE" ]; then
    fail "cas stress: no result line in dmesg -- did cas_stress run at all?"
else
    S_OK="$(echo "$STRESS_LINE" | grep -oP '\K[0-9]+(?= successful increments)')"
    S_FINAL="$(echo "$STRESS_LINE" | grep -oP 'counter reads \K[0-9]+')"
    S_ERR="$(echo "$STRESS_LINE" | grep -oP '\K[0-9]+(?= errors)')"
    if [ "$S_ERR" != "0" ]; then
        fail "cas stress: $S_ERR of the increments returned an error"
    else
        pass "cas stress: every increment reported success ($S_OK)"
    fi
    if [ "$S_FINAL" = "$S_OK" ]; then
        pass "cas stress: the counter equals the successful increments ($S_FINAL) -- no lost updates"
    else
        fail "cas stress: $S_OK increments succeeded but the counter reads $S_FINAL ($((S_OK - S_FINAL)) lost)"
    fi
fi

log "checking concurrent creates in different directories get distinct inodes"
# Each process works in its own directory, so nslock's per-inode lock on
# the parent does NOT serialise them and the shared global inode bitmap
# underneath is genuinely contended.
CAS_PROCS=8
CAS_PER=300
CAS_WANT=$((CAS_PROCS * CAS_PER))
mkdir "$MNT/par"
if "$PARALLEL_CREATE" "$MNT/par" "$CAS_PROCS" "$CAS_PER"; then
    pass "parallel create: all $CAS_WANT creates succeeded"
else
    fail "parallel create: at least one child could not create its files"
fi
sync

CAS_FILES="$(find "$MNT/par" -type f | wc -l)"
CAS_INODES="$(find "$MNT/par" -type f -printf '%i\n' | sort -u | wc -l)"
if [ "$CAS_FILES" != "$CAS_WANT" ]; then
    fail "parallel create: $CAS_FILES files on disk, expected $CAS_WANT"
elif [ "$CAS_INODES" = "$CAS_FILES" ]; then
    pass "parallel create: $CAS_FILES files hold $CAS_INODES distinct inode numbers"
else
    CAS_DUPS="$(find "$MNT/par" -type f -printf '%i\n' | sort | uniq -d | tr '\n' ' ')"
    fail "parallel create: $CAS_FILES files but only $CAS_INODES distinct inodes -- reused: $CAS_DUPS"
fi

ct_umount "$MNT"

log "checking fsck agrees after the concurrent run"
# The nlink-vs-entries cross-check is what names the fault directly: a
# reused inode number shows up as one inode with nlink=1 that two
# directory entries point at.
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if echo "$FSCK_OUT" | grep -q "cetrafs fsck: OK"; then
    pass "fsck: clean after $CAS_WANT concurrent creates"
else
    fail "fsck: reported problems after the concurrent run: $(echo "$FSCK_OUT" | grep -iE 'ERR|WARN' | head -3 | tr '\n' ' ')"
fi

ct_exit
