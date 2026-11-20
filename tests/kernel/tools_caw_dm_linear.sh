#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the tools never send COMPARE AND WRITE through a device-mapper node that addresses another LBA space
#
# fsck -r, growfs and mkfs claim the registry by COMPARE AND WRITE when
# the device has it. Through a dm-linear node that does not start at the
# disk's block 0 -- a kpartx partition of a multipath map, an LV -- the
# command reaches the disk under it with the volume's LBA, so the swap
# lands that far before the row: the claim always miscompared ("another
# repair claimed this volume") or, over zeros, wrote a stray row (audit
# 2026-11-15 B-26). Only a whole multipath map, whose SCSI READ of block
# 0 is the device's block 0, is used for CAW now; the rest take the
# fallback a device without CAW takes.
#
# A LIO loopback disk (it has CAW) under a dm-linear node starting 1 MiB
# in; the volume is made on the node:
#   1. fsck -r on the node does not claim by COMPARE AND WRITE, and its
#      repair completes; fsck clean;
#   2. the disk itself still claims by CAW (the setup reaches CAW).
#
# DISCRIMINATION: CETRAFS_TEST_TOOLS_DM_ANY=1 (no guard, as before): the
# claim goes by CAW through the node and fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 700 tcdl)"
DISK="$(ct_lio_disks "$IMG" 1)" || { skip "no LIO loopback target here"; ct_exit; }

# 2 first, before the node exists: on the disk itself the tools do claim
# by CAW. (Once the dm node holds the disk, a destructive tool's exclusive
# open of the disk is refused, as it must be under a multipath map.)
ct_mkfs "$DISK" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
OUT="$("$FSCK" -r "$DISK" 2>&1 || true)"
grep -q "registry claim written by COMPARE AND WRITE" <<<"$OUT" ||
    { fail "setup: fsck -r did not use CAW on the LIO disk itself: $(grep -m2 'registry claim\|ERR' <<<"$OUT")"; ct_exit; }
pass "2: the disk itself claims by COMPARE AND WRITE"
NAME="ct-tcdl-$$"
SECT="$(blockdev --getsz "$DISK")"
dmsetup create "$NAME" --table "0 $((SECT - 2048)) linear $DISK 2048" ||
    { skip "dm-linear is not available"; ct_exit; }
ct_track dm "$NAME"
NODE="/dev/mapper/$NAME"
udevadm settle 2>/dev/null || true

ct_mkfs "$NODE" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
# fsck -r -> "caw=<0|1> rc=<n>"
repair() {
    local out rc=0 caw=0
    out="$(env ${1:+$1} "$FSCK" -r "$NODE" 2>&1)" || rc=$?
    grep -q "registry claim written by COMPARE AND WRITE" <<<"$out" && caw=1
    echo "caw=$caw rc=$rc"
    [ "$rc" = 0 ] || grep -m3 -E "ERR|claim|refus" <<<"$out" >&2 || true
}
R="$(repair)"
C="$(repair CETRAFS_TEST_TOOLS_DM_ANY=1)"
log "fixed: $R  control (no guard): $C"
[ "$R" = "caw=0 rc=0" ] && pass "1: through the offset node: no COMPARE AND WRITE, and the repair completed" ||
    fail "1: $R"
F="$("$FSCK" "$NODE" 2>&1)" && pass "1: fsck clean" || fail "1: fsck: $(grep -m3 -E '^ERR' <<<"$F")"
[ "$C" != "caw=0 rc=0" ] && pass "control: without the guard the claim was sent by CAW through the node and failed ($C)" ||
    fail "control: $C -- SCSI commands do not pass through this dm node; the suite does not reach the hazard"
ct_exit
