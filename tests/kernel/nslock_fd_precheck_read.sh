#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace release whose ownership precheck cannot read retries, and never publishes half
#
# Before a release publishes a directory's staged file sector (its new
# size) it reads the namespace sector to confirm the lock is still ours.
# When that read failed, the file sector was withheld and the sector-0
# swap went out anyway -- dirent_seq published over a size that never
# landed, and every later create or unlink adjusts the size it reads, so
# the directory stayed one entry short for good (re-audit of the
# 2026-11-14 fixes). The read is now retried; one that persists stops
# the mount, which refuses the swap.
#
#   1. two failed reads, then a good one: after a remount the directory
#      has the size of its entries;
#   2. reads that never succeed: the mount stops (the next create fails)
#      instead of going on.
#
# DISCRIMINATION: nslock_fd_precheck_quiet withholds on the first
# failure and goes on, as before -- the size is then one entry short.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in nslock_fd_precheck_read_fail nslock_fd_precheck_quiet; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
DE=266 # sizeof(cetrafs_dirent_t)
MNT="$(ct_mnt nsfdpr)"
ct_track mnt "$MNT"
ct_param_set nslock_fd_precheck_read_fail 0
ct_param_set nslock_fd_precheck_quiet 0
P=/sys/module/cetrafs/parameters

# <fails> <quiet> -> "<consumed> <size-after-remount>"
probe() {
    local dev left got
    dev="$(ct_dev 560 "nsfdpr$1$2")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    echo "$2" >$P/nslock_fd_precheck_quiet
    echo "$1" >$P/nslock_fd_precheck_read_fail
    : >"$MNT/d/a"
    left="$(cat $P/nslock_fd_precheck_read_fail)"
    echo 0 >$P/nslock_fd_precheck_read_fail
    echo 0 >$P/nslock_fd_precheck_quiet
    : >"$MNT/d/b"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    got="$(stat -c %s "$MNT/d")"
    ct_umount "$MNT"
    echo "$(($1 - left)) $got"
}

want=$((4 * DE))
set -- $(probe 2 0)
[ "$1" = 2 ] || { fail "setup: the create's precheck read was failed $1 time(s), expected 2"; ct_exit; }
[ "$2" = "$want" ] && pass "1: two failed reads were retried: the directory is $2 bytes" ||
    fail "1: the directory is $2 bytes, not $want, after two failed precheck reads"

dev="$(ct_dev 560 nsfdprp)"
ct_mkfs_small "$dev" >/dev/null
ct_mount "$dev" "$MNT"
mkdir "$MNT/d"
echo 1000 >$P/nslock_fd_precheck_read_fail
: >"$MNT/d/a" 2>/dev/null || true
echo 0 >$P/nslock_fd_precheck_read_fail
if : >"$MNT/d/b" 2>/dev/null; then
    fail "2: the precheck never read, and the mount went on accepting creates"
else
    pass "2: a precheck that never reads stops the mount"
fi
umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true

set -- $(probe 1 1)
[ "$1" = 1 ] && [ "$2" != "$want" ] &&
    pass "control: one quiet failure leaves the directory $2 bytes, not $want -- the suite discriminates" ||
    fail "control: consumed $1, size $2 -- the suite does not discriminate"
ct_exit
