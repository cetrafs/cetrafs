#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the cached free-inode count stays exact under concurrency
#
# There is no on-disk free-inode counter: the number statfs reports is
# seeded by one bitmap scan at mount and adjusted incrementally from then
# on. That makes it fragile in two specific ways, neither of which was
# covered:
#
#  * It was a plain u64 += from every create and every unlink, with no
#    lock. The bitmap underneath is serialised (a compare-and-swap, or
#    the cas_mutex fallback where the device has no CAW) but the counter
#    sits outside that, so two creates in different directories -- which
#    take different namespace locks and so really do run in parallel --
#    could lose one of the decrements.
#  * Freeing an inode number that was already free credited the count
#    anyway. The bitmap layer warned about it and then reported success,
#    so the caller could not tell a real free from a no-op.
#
# Neither corrupts anything: allocation scans the bitmap and returns
# -ENOSPC on its own, so nothing decides on this number. It just makes
# `df -i` lie, permanently -- the count is never reconciled against the
# bitmap again for the life of the mount.
#
# DISCRIMINATION, stated honestly: the lost-update race is NOT
# demonstrated here. Restoring the unsynchronised read-modify-write and
# running this three times produced an exact count every time -- the
# window is a load-add-store and this host has 2 CPUs, so two creates
# almost never land inside it. The fix is correct by inspection (an
# unsynchronised RMW reachable from two genuinely parallel creates, which
# tests/kernel/cas_concurrency.sh proves do happen) and free, but this
# suite asserts the INVARIANT -- the count is exact, and agrees with a
# fresh bitmap scan -- rather than proving the race. The third assertion
# is the valuable one: it compares the incrementally-maintained number
# against what a remount computes from scratch, which catches a drift
# from any cause, including ones not thought of here.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PARALLEL_CREATE="$(ct_helper parallel_create)"

DEV="$(ct_dev 560 fia)"
MNT="$(ct_mnt fia)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

free_inodes() { stat -f -c '%d' "$MNT"; }

START="$(free_inodes)"
log "checking the count is exact after concurrent creates (start: $START free)"
PROCS=8
PER=250
WANT=$((PROCS * PER))
mkdir "$MNT/par"
"$PARALLEL_CREATE" "$MNT/par" "$PROCS" "$PER" >/dev/null
sync
# WANT files, PROCS per-writer directories, and the "par" directory the
# test made itself. Counting that last one is not pedantry: an exact
# assertion is the only kind that can detect a single lost decrement.
EXPECT=$((START - WANT - PROCS - 1))
GOT="$(free_inodes)"
if [ "$GOT" = "$EXPECT" ]; then
    pass "free inodes: exact after $WANT concurrent creates ($GOT)"
else
    fail "free inodes: $GOT after $WANT concurrent creates, expected $EXPECT (drifted by $((GOT - EXPECT)))"
fi

log "checking the count returns exactly to its starting value"
rm -rf "$MNT/par"
sync
BACK="$(free_inodes)"
[ "$BACK" = "$START" ] && pass "free inodes: back to $START after deleting everything" ||
    fail "free inodes: $BACK after deleting everything, expected $START"

# A remount reseeds the count from a full bitmap scan, so comparing the
# two is the check that the incremental arithmetic agreed with reality --
# the one thing nothing reconciles while mounted.
log "checking the incremental count agrees with a fresh bitmap scan"
: >"$MNT/keep1"
mkdir "$MNT/keepd"
sync
LIVE="$(free_inodes)"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
SCANNED="$(free_inodes)"
[ "$LIVE" = "$SCANNED" ] && pass "free inodes: incremental ($LIVE) matches the remount scan ($SCANNED)" ||
    fail "free inodes: incremental said $LIVE, a fresh scan says $SCANNED"
ct_umount "$MNT"

ct_exit
