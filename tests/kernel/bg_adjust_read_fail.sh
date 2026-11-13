#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation whose descriptor cannot be read still reaches the free count
#
# cetrafs_bg_adjust_free_blocks() is told about every bitmap change after
# it is made, and its callers ignore its return. It read the Block
# Group's descriptor -- to find the owning Zone Group for the aggregate's
# roll-up -- BEFORE accruing the delta, and a failed read returned with
# nothing accrued: the bits were set and the count never heard of them.
# A full group then reads free (class 52's state, reached another way),
# and fsck finds the count and the bitmap apart. The delta is now accrued
# first, and the roll-up falls back to the in-memory owner map.
#
# Staged: bg_adjust_read_fail makes the next adjusts find their
# descriptor unreadable while a file writes 64 blocks.
#
#  1. the free count drops by the 64 blocks, and fsck is clean;
#  2. control (bg_adjust_old_order=1): the count does not move, and fsck
#     reports the Block Group's count apart from its bitmap.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_adjust_read_fail bg_adjust_old_order; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 1200 bgadj)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgadj)"
ct_track mnt "$MNT"
ct_param_set bg_adjust_read_fail 0
ct_param_set bg_adjust_old_order 0
ct_param_set alloc_run_blocks 0 # every block allocated is one the test wrote
ct_param_set scrub 0
ct_param_set auto_defrag 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <tag>: sets DROP (free count before - after) and FSCK (its output)
run() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 2 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    touch "$MNT/f"
    sync -f "$MNT"
    local before
    before="$(info free_data_blocks)"
    ct_param_set bg_adjust_read_fail 100000
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 conv=fsync status=none
    ct_param_set bg_adjust_read_fail 0
    DROP=$((before - $(info free_data_blocks)))
    ct_umount "$MNT"
    FSCK="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
    log "$1: the free count dropped by $DROP for 64 blocks written; fsck rc $FSCK_RC"
}

# ------------------------------------------------------------------ 2
log "2: control -- the old order drops the delta with the failed read"
ct_param_set bg_adjust_old_order 1
run control
ct_param_set bg_adjust_old_order 0
[ "$DROP" -lt 64 ] && pass "control: the count missed the allocations (dropped by $DROP)" ||
    fail "control: the count dropped by $DROP -- the suite cannot tell the two apart"
[ "$FSCK_RC" != 0 ] && pass "control: fsck finds the count apart from the bitmap" ||
    fail "control: fsck is clean -- it does not see the lost delta"

# ------------------------------------------------------------------ 1
log "1: a failed descriptor read in the adjust"
run fix
[ "$DROP" = 64 ] && pass "1: the free count dropped by the 64 blocks written" ||
    fail "1: the free count dropped by $DROP for 64 blocks written"
[ "$FSCK_RC" = 0 ] && pass "1: fsck clean" || fail "1: fsck: $(grep -m3 ERR <<<"$FSCK" | tr '\n' ' ')"
ct_exit
