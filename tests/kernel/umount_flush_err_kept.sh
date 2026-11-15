#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed extent-tree flush at unmount is not announced as a clean departure
#
# Unmount flushes the held-back extent-tree blocks, then the allocation
# bitmaps, and announces a CLEAN departure only if everything of ours
# reached the device: a peer takes a cleanly departed node's Zone Groups
# at once, with no fence and no replay. The bitmap flush's result used to
# be ASSIGNED to the error the tree flush had set, so a failed tree flush
# followed by a bitmap flush with nothing to do read as a clean departure
# (audit 2026-11-14 A-9).
#
# TEST ONLY umount_tree_flush_fail=1 makes unmount's tree flush report
# -EIO; the bitmaps have nothing dirty.
#   1. the row's recorded departure is not CLEAN;
#   2. unmount says it is not announcing one.
#
# DISCRIMINATION: a module built with the plain assignment back: 1 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/umount_tree_flush_fail ] || { skip "umount_tree_flush_fail is missing"; ct_exit; }
NP="$(ct_helper node_poke)"
DEV="$(ct_dev 600 ufe)"
MNT="$(ct_mnt ufe)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -N 1024 -f >/dev/null
ct_param_set umount_tree_flush_fail 0
ct_mount "$DEV" "$MNT"
row="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
dd if=/dev/zero of="$MNT/f" bs=1M count=4 conv=fsync status=none
mark="cetrafs-ufe-$$-$RANDOM"
echo "$mark" >/dev/kmsg
echo 1 >/sys/module/cetrafs/parameters/umount_tree_flush_fail
ct_umount "$MNT"
echo 0 >/sys/module/cetrafs/parameters/umount_tree_flush_fail
dep="$("$NP" "$DEV" "$row" | sed -n 's/.*departure=\([0-9]*\).*/\1/p')"
msg="$(dmesg | sed -n "/$mark/,\$p")"
grep -q "deferred extent-tree blocks could not be written" <<<"$msg" ||
    { fail "setup: unmount's tree flush did not fail"; ct_exit; }
pass "setup: unmount's tree flush failed"
[ -n "$dep" ] && [ "$dep" != 1 ] && pass "1: row $row's departure is $dep, not CLEAN" ||
    fail "1: row $row's departure is '${dep}' -- a failed flush announced as a clean departure"
grep -q "not announcing a clean departure" <<<"$msg" && pass "2: unmount says it is not announcing one" ||
    fail "2: unmount said nothing about the failed flush's departure"
ct_exit
