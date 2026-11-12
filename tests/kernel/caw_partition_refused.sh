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
# Staged twice: on a real CAW target built on this host (ct_lio_disks),
# and on a scsi_debug disk -- a different SCSI driver under the same
# plain-SCSI branch, so the refusal is not something LIO happens to do.
# The scsi_debug case skips (saying so) where the module is missing,
# already in use, or its disk is claimed by something else (multipathd).
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
MNT="$(ct_mnt cawpart)"
ct_track mnt "$MNT"
caw_line() { grep '^caw:' "$(ct_procdir "$1")/properties"; }

# part_case <label> <disk>: the whole disk drives CAW; its partition must not.
part_case() {
    local tag="$1" DISK="${2#/dev/}" MO WHOLE PART P MARK OUT
    # The whole disk first: it must drive CAW, or nothing below tells the
    # fix from a device without it.
    MO="$(ct_mkfs_small "/dev/$DISK" 2>&1)" || { fail "$tag: setup: mkfs /dev/$DISK: $(tail -3 <<<"$MO")"; return; }
    ct_mount "/dev/$DISK" "$MNT"
    require_cetrafs_mount "$MNT"
    WHOLE="$(caw_line "/dev/$DISK")"
    ct_umount "$MNT"
    if ! grep -q 'available=yes' <<<"$WHOLE"; then
        # LIO is built to offer it; scsi_debug's support depends on the kernel.
        [ "$tag" = LIO ] && fail "$tag: setup: the whole disk does not offer CAW ($WHOLE)" ||
            skip "$tag: the whole disk does not offer CAW here ($WHOLE)"
        return
    fi
    pass "$tag: setup: the whole disk drives COMPARE AND WRITE ($WHOLE)"

    wipefs -a -q "/dev/$DISK"
    echo 'start=2048, type=83' | sfdisk -q "/dev/$DISK" >/dev/null
    blockdev --rereadpt "/dev/$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    PART="/dev/${DISK}1"
    for _ in $(seq 1 50); do [ -b "$PART" ] && break; sleep 0.1; done
    [ -b "$PART" ] || { fail "$tag: setup: $PART did not appear after partitioning"; return; }
    [ "$(cat "/sys/class/block/${DISK}1/start")" -gt 0 ] ||
        { fail "$tag: setup: the partition starts at sector 0 -- an offset is what this is about"; return; }

    MO="$(ct_mkfs_small "$PART" 2>&1)" || { fail "$tag: setup: mkfs $PART: $(tail -3 <<<"$MO")"; return; }
    MARK="$(dmesg_mark)"
    ct_mount "$PART" "$MNT"
    require_cetrafs_mount "$MNT"
    P="$(caw_line "$PART")"
    grep -q 'available=no' <<<"$P" && pass "$tag: the partition is not driven with CAW ($P)" ||
        fail "$tag: the partition drives COMPARE AND WRITE at partition-relative LBAs on the whole disk ($P)"
    dmesg_since "$MARK" | grep -q 'is a partition' && pass "$tag: and the mount says why" ||
        fail "$tag: no log line names the partition"
    echo x >"$MNT/f" && pass "$tag: the one-mounter volume works" || fail "$tag: a write to the partition mount failed"
    ct_umount "$MNT"
    OUT="$(ct_fsck "$PART" 2>&1 || true)"
    grep -qE '^ERR' <<<"$OUT" && fail "$tag: fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "$tag: fsck clean"
}

IMG="$(ct_image 700 cawpart)"
WHY="$(ct_tmp cawpart-why)"
if DISK="$(ct_lio_disks "$IMG" 1 2>"$WHY")"; then
    part_case LIO "$DISK"
else
    skip "LIO: $(cat "$WHY")"
fi

# scsi_debug: a fresh instance only -- one already loaded belongs to
# something else.
sd_disk() {
    local d
    for d in /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*/block/*; do
        [ -e "$d" ] && { basename "$d"; return 0; }
    done
    return 1
}
if ! modinfo scsi_debug >/dev/null 2>&1; then
    skip "scsi_debug: the module is not available"
elif lsmod | grep -q '^scsi_debug '; then
    skip "scsi_debug: already loaded by something else"
elif ! modprobe scsi_debug dev_size_mb=700 sector_size=512 2>/dev/null; then
    skip "scsi_debug: modprobe failed"
else
    ct_track cmd "modprobe -r scsi_debug"
    udevadm settle 2>/dev/null || true
    SD=""
    for _ in $(seq 1 50); do SD="$(sd_disk)" && break; sleep 0.1; done
    if [ -z "$SD" ]; then
        fail "scsi_debug: setup: its disk never appeared"
    elif [ -n "$(ls "/sys/class/block/$SD/holders" 2>/dev/null)" ]; then
        skip "scsi_debug: /dev/$SD is claimed by $(ls "/sys/class/block/$SD/holders" | tr '\n' ' ')(multipathd?)"
    else
        part_case scsi_debug "/dev/$SD"
    fi
fi
ct_exit
