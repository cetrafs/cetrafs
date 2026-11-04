#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a partition of a SCSI disk is never driven with COMPARE AND WRITE
#
# A partition's gendisk is the whole disk's, so the SCSI device CAW
# discovery found for /dev/sdX1 was the whole disk's -- and every swap
# went to it at a partition-relative LBA, bd_start_sect too early. Most
# miscompare; a compare of zeros against zeros succeeds and writes the
# wrong block of a shared LUN. The dm branch already refused a path with
# an offset; the plain-SCSI branch did not.
#
# Staged on a real CAW target built on this host (ct_lio_disks).
# The whole disk must report CAW available (otherwise the partition
# result proves nothing); its partition must report it unavailable, so
# the volume falls under the one-mounter gate.
#
# DISCRIMINATION: without the partition check the partition mount
# reports available=yes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v sfdisk >/dev/null || { skip "sfdisk is missing"; ct_exit; }
IMG="$(ct_image 700 cawpart)"
MNT="$(ct_mnt cawpart)"
WHY="$(ct_tmp cawpart-why)"
DISK="$(ct_lio_disks "$IMG" 1 2>"$WHY")" || { skip "$(cat "$WHY")"; ct_exit; }
DISK="${DISK#/dev/}"
ct_track mnt "$MNT"

caw_line() { grep '^caw:' "$(ct_procdir "$1")/properties"; }

# The whole disk first: it must drive CAW, or nothing below tells the
# fix from a device without it.
MO="$(ct_mkfs_small "/dev/$DISK" 2>&1)" || { fail "setup: mkfs /dev/$DISK: $(tail -3 <<<"$MO")"; ct_exit; }
ct_mount "/dev/$DISK" "$MNT"
require_cetrafs_mount "$MNT"
WHOLE="$(caw_line "/dev/$DISK")"
ct_umount "$MNT"
grep -q 'available=yes' <<<"$WHOLE" ||
    { fail "setup: the whole LIO disk does not offer CAW ($WHOLE)"; ct_exit; }
pass "setup: the whole disk drives COMPARE AND WRITE ($WHOLE)"

wipefs -a -q "/dev/$DISK"
echo 'start=2048, type=83' | sfdisk -q "/dev/$DISK" >/dev/null
blockdev --rereadpt "/dev/$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true
PART="/dev/${DISK}1"
for _ in $(seq 1 50); do [ -b "$PART" ] && break; sleep 0.1; done
[ -b "$PART" ] || { fail "setup: $PART did not appear after partitioning"; ct_exit; }
[ "$(cat "/sys/class/block/${DISK}1/start")" -gt 0 ] ||
    { fail "setup: the partition starts at sector 0 -- an offset is what this is about"; ct_exit; }

MO="$(ct_mkfs_small "$PART" 2>&1)" || { fail "setup: mkfs $PART: $(tail -3 <<<"$MO")"; ct_exit; }
MARK="$(dmesg_mark)"
ct_mount "$PART" "$MNT"
require_cetrafs_mount "$MNT"
P="$(caw_line "$PART")"
grep -q 'available=no' <<<"$P" && pass "the partition is not driven with CAW ($P)" ||
    fail "the partition drives COMPARE AND WRITE at partition-relative LBAs on the whole disk ($P)"
dmesg_since "$MARK" | grep -q 'is a partition' && pass "and the mount says why" ||
    fail "no log line names the partition"
echo x >"$MNT/f" && pass "the one-mounter volume works" || fail "a write to the partition mount failed"
ct_umount "$MNT"
OUT="$(ct_fsck "$PART" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
