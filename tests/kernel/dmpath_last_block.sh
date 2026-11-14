#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a path is 1:1 only if its LAST block matches too, not just block 0
#
# The identity guard sends COMPARE AND WRITE down a SCSI path only when
# the path is a 1:1 map of the stacked device. It compared block 0 alone,
# so a multi-segment linear map that starts on the same LUN and ends on
# another passed: COMPARE AND WRITE then aimed at the wrong LUN's blocks
# (audit L4). The guard now compares the last block too, and refuses a
# path whose last block differs.
#
# Rig: two LIO LUNs, A and B, backed by separate images of equal size.
#  - control: a dm-linear map over all of LUN A is 1:1 -> the mount finds
#    a CAW path through it.
#  - the map: sectors [0, S-8) on LUN A, the last 4 KiB on LUN B. Block 0
#    is LUN A's, so the first-block compare passes; LUN A's own last block
#    (outside the map, scribbled with random bytes) differs from the map's.
#    The mount must refuse LUN A: no "sending COMPARE AND WRITE via".
#
# DISCRIMINATION: with the block-0-only compare (the pre-fix code) the map
# passes and the mount logs "sending COMPARE AND WRITE via" for LUN A.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_linear 2>/dev/null || true

IMG_A="$(ct_image 600 dmlbA)"
IMG_B="$(ct_image 600 dmlbB)"
DA="$(ct_lio_disks "$IMG_A" 1)" || { skip "no LIO loopback target here"; ct_exit; }
DB="$(ct_lio_disks "$IMG_B" 1)" || { skip "no LIO loopback target here"; ct_exit; }
SECTORS="$(blockdev --getsz "$DA")"
[ "$SECTORS" = "$(blockdev --getsz "$DB")" ] && [ $((SECTORS % 8)) -eq 0 ] ||
    { fail "setup: the two LUNs differ in size ($SECTORS, $(blockdev --getsz "$DB"))"; ct_exit; }
MNT="$(ct_mnt dmlb)"
ct_track mnt "$MNT"

# dm_map <name> <table lines...>: create a dm node from a table on stdin
dm_map() {
    local name="$1"; shift
    printf '%s\n' "$@" | dmsetup create "$name" || return 1
    ct_track dm "$name"
    udevadm settle 2>/dev/null || true
}

# ------------------------------------------------------------------- control
C1="ctdmlb1$$"
dm_map "$C1" "0 $SECTORS linear $DA 0" || { skip "device-mapper linear is not available"; ct_exit; }
DEV1="/dev/mapper/$C1"
ct_mkfs "$DEV1" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV1" "$MNT"
require_cetrafs_mount "$MNT"
CTRL="$(dmesg_since "$MARK" | grep -c 'sending COMPARE AND WRITE via' || true)"
ct_umount "$MNT"
dmsetup remove "$C1" 2>/dev/null || true
[ "$CTRL" -ge 1 ] || { fail "setup: the 1:1 control map found no CAW path"; ct_exit; }
pass "control: a 1:1 map of LUN A is accepted and CAW goes through it"

# ------------------------------------------------------------------- the map
# LUN A's last 4 KiB lies outside the map (its sectors end at S-8): scribble it.
dd if=/dev/urandom of="$DA" bs=4096 seek=$(((SECTORS / 8) - 1)) count=1 conv=fsync status=none 2>/dev/null ||
    { fail "setup: could not write LUN A's last block"; ct_exit; }
N1="ctdmlb2$$"
dm_map "$N1" "0 $((SECTORS - 8)) linear $DA 0" "$((SECTORS - 8)) 8 linear $DB 0" ||
    { fail "setup: the two-segment map did not load"; ct_exit; }
DEV2="/dev/mapper/$N1"
ct_mkfs "$DEV2" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV2" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
LOG="$(dmesg_since "$MARK")"
dmsetup remove "$N1" 2>/dev/null || true

grep -q 'last block differs from the mapped device' <<<"$LOG" &&
    pass "1: the last-block compare found the map is not 1:1" ||
    fail "1: the guard did not compare the last block"
if grep -q 'sending COMPARE AND WRITE via' <<<"$LOG"; then
    fail "1: COMPARE AND WRITE was aimed at a path whose last block is another LUN's"
else
    pass "1: and no COMPARE AND WRITE was sent down LUN A"
fi
ct_exit
