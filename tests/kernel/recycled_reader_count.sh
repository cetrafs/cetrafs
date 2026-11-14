#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new inode's first reader publishes its presence, whatever the slab object held before
#
# A node's first local reader of a file sets its bit in the record's
# read_open_nodes, which stops a peer truncating, unlinking or
# write-opening the file under it. "First" is read_opener_count going
# 0 -> 1. A nofilelock close whose publish failed keeps that count at 1
# until the heartbeat retries, and an inode evicted meanwhile went back
# to the slab with it: the next file in that object never published its
# first reader (audit 2026-11-14 L-F1). ->alloc_inode now resets the
# open counters of every new inode.
#
# alloc_recycled_reader plants exactly that state -- every new inode
# arrives with a reader count of 1 -- and a file is then opened for
# reading from a cold cache: its bit must be on the device.
#
# DISCRIMINATION: alloc_keeps_counts keeps the counts ->alloc_inode
# finds; the bit is then never published.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in alloc_recycled_reader alloc_keeps_counts; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_loop "$(ct_image 560 rrc)")"
MNT="$(ct_mnt rrc)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_recycled_reader 0
ct_param_set alloc_keeps_counts 0
echo data >"$MNT/y"
sync
INO="$(stat -c %i "$MNT/y")"
readers() { sed -n 's/.*readers=\(0x[0-9a-f]*\).*/\1/p' <<<"$("$LOCK_POKE" "$DEV" "$INO")"; }

# <keeps_counts 0|1> -> the record's read_open_nodes while a reader holds y
probe() {
    local r
    echo "$1" >/sys/module/cetrafs/parameters/alloc_keeps_counts
    echo 3 >/proc/sys/vm/drop_caches # y is instantiated afresh by the open
    echo 1 >/sys/module/cetrafs/parameters/alloc_recycled_reader
    exec 7<"$MNT/y"
    echo 0 >/sys/module/cetrafs/parameters/alloc_recycled_reader
    r="$(readers)"
    exec 7<&-
    echo 0 >/sys/module/cetrafs/parameters/alloc_keeps_counts
    echo "$r"
}
R="$(probe 0)"
[ -n "$R" ] && [ "$R" != 0x0 ] && pass "a reader of a freshly instantiated file publishes its presence ($R)" ||
    fail "the reader's presence is not on the device (read_open_nodes=$R) -- a peer would see no reader"
R0="$(probe 1)"
[ "$R0" = 0x0 ] && pass "control: a recycled reader count hides the first reader -- the suite discriminates" ||
    fail "control: with the count kept the bit was still published ($R0) -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
