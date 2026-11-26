#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a dm node whose /sys cannot be read is refused, never taken for "no CAW"
#
# The dm path walk finds the SCSI path under a multipath map by reading
# /sys/block/<dm>/slaves. Any failure there read as "nothing stacked
# under it", so the volume mounted on the no-CAW fallback -- one node
# only, beside peers that may be using real COMPARE AND WRITE. Linux 7.3
# made every such lookup fail (the walk started at init_task's root,
# which is no longer the real root; dmpath.c cetrafs_init_root()), and
# every multipath LUN mounted that way in silence.
#
# Rig: one LIO LUN under a 1:1 dm-linear map.
#  - control: the map mounts and CAW goes through the LUN.
#  - dmpath_sysfs_hidden=1 (every /sys lookup of the walk fails ENOENT,
#    as on 7.3): the mount is refused, and says why; it does not mount
#    with class=none.
#  - restored: the map mounts with CAW again.
#
# DISCRIMINATION: without the refusal (caw.c's prc check, or dmpath.c's
# depth-0 visibility check) case 2 mounts on the no-CAW fallback.
# The root fix itself is covered on 7.3 by every dmpath_*/caw_* suite
# that maps a LIO disk: all of them found no CAW path before it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_linear 2>/dev/null || true
[ -w /sys/module/cetrafs/parameters/dmpath_sysfs_hidden ] || { skip "dmpath_sysfs_hidden is missing"; ct_exit; }

IMG="$(ct_image 600 dmsu)"
DA="$(ct_lio_disks "$IMG" 1)" || { skip "no LIO loopback target here"; ct_exit; }
SECTORS="$(blockdev --getsz "$DA")"
MNT="$(ct_mnt dmsu)"
ct_track mnt "$MNT"

M="ctdmsu$$"
printf '0 %s linear %s 0\n' "$SECTORS" "$DA" | dmsetup create "$M" ||
    { skip "device-mapper linear is not available"; ct_exit; }
ct_track dm "$M"
udevadm settle 2>/dev/null || true
DEV="/dev/mapper/$M"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null

# ------------------------------------------------------------------ control
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
ct_umount "$MNT"
LOG="$(dmesg_since "$MARK")"
grep -q 'sending COMPARE AND WRITE via' <<<"$LOG" ||
    { fail "setup: the 1:1 map found no CAW path even with /sys readable"; ct_exit; }
pass "control: the 1:1 map mounts and CAW goes through the LUN"

# --------------------------------------------------------- /sys unreachable
ct_param_set dmpath_sysfs_hidden 1
MARK="$(dmesg_mark)"
rc=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
LOG="$(dmesg_since "$MARK")"
if [ "$rc" -eq 0 ]; then
    ct_umount "$MNT"
    fail "2: the mount succeeded with the walk unable to read /sys"
else
    pass "2: the mount is refused (rc=$rc)"
fi
grep -q 'cannot be read' <<<"$LOG" &&
    pass "2: and says /sys could not be read" ||
    fail "2: the refusal does not say why"
if grep -q 'class=none' <<<"$LOG"; then
    fail "2: the walk's failure was taken for a device with no CAW"
else
    pass "2: it was not taken for a device with no CAW"
fi
ct_param_set dmpath_sysfs_hidden 0

# ----------------------------------------------------------------- restored
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
ct_umount "$MNT"
LOG="$(dmesg_since "$MARK")"
grep -q 'sending COMPARE AND WRITE via' <<<"$LOG" &&
    pass "3: with /sys readable again the map mounts with CAW" ||
    fail "3: the map found no CAW path after /sys came back"

ct_fsck "$DEV" >/dev/null && pass "fsck clean" || fail "fsck not clean"
ct_exit
