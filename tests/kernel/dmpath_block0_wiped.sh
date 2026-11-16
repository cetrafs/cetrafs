#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a wiped block 0 under a live multipath mount does not stop the node at its next path event
#
# A CAW path under a dm multipath map is identified by the cetrafs
# superblock at block 0, read through the path and through the map. A
# block 0 wiped under live nodes -- an admin's "wipe", a stray partition
# table -- changed nothing until the next path event, a routine failover
# included: then every path was refused, the next compare-and-swap had
# nowhere to go and the node stopped, with nothing to connect it to the
# wipe (audit 2026-11-15 B-15). A path is now identified by the copy of
# block 0 at block 2048 (A-7) when block 0 no longer can be.
#
# Two LIO paths, ALUA, under a multipath map; block 0 zeroed through the
# map; the port in use demoted, so the next CAW re-resolves a path:
#   1. the re-resolution identified the other path by the copy;
#   2. creates after it succeed, and the mount runs on.
#
# DISCRIMINATION: dmpath_no_sb_copy=1 (block 0 alone, as before): no path
# is identified and the mount stops.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
[ -w /sys/module/cetrafs/parameters/dmpath_no_sb_copy ] || { skip "dmpath_no_sb_copy is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
ct_param_set dmpath_no_sb_copy 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CT_LIO_ALUA=1
via() { sed -n 's/.*sending COMPARE AND WRITE via \([a-z]*\).*/\1/p'; }
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <no_sb_copy 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark used rc=0
    img="$(ct_image 600 "dbw$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="${3#/dev/}" d2="${4#/dev/}"
    [ "$(cat "/sys/block/$d1/device/dh_state")" = alua ] || { skip "scsi_dh_alua did not attach"; ct_exit; }
    name="ctdbw$1$$"
    sectors="$(blockdev --getsz "/dev/$d1")"
    m1="$(lsblk -dno MAJ:MIN "/dev/$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "/dev/$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "dbw$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    : >"$mnt/a0" || rc=1
    used="$(dmesg_since "$mark" | via | tail -1)"
    [ -n "$used" ] || { fail "setup: no CAW path was resolved"; ct_exit; }
    # block 0 wiped under the live mount
    dd if=/dev/zero of="$dev" bs=4096 count=1 oflag=direct conv=notrunc status=none
    echo "$2" >$P/dmpath_no_sb_copy
    mark="$(dmesg_mark)"
    ct_lio_alua "$used" 1 || { fail "setup: could not demote $used"; ct_exit; }
    for i in 1 2 3; do : >"$mnt/b$i" 2>/dev/null || rc=1; done
    sleep 1
    RES="used=$used rc=$rc after=$(dmesg_since "$mark" | via | tail -1)"
    RES="$RES bycopy=$(dmesg_since "$mark" | grep -c 'identified by its copy at block' || true)"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED\|SELF-FENCED' || true)"
    echo 0 >$P/dmpath_no_sb_copy
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
}

round c 1
C="$RES"
log "control (block 0 alone): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get bycopy "$R")" -ge 1 ] && [ -n "$(get after "$R")" ] && [ "$(get after "$R")" != "$(get used "$R")" ] &&
    pass "1: the re-resolution identified $(get after "$R") by the copy of block 0" || fail "1: $R"
[ "$(get rc "$R")" = 0 ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "2: creates after the path event succeeded; the mount runs on" || fail "2: $R"
{ [ "$(get stopped "$C")" -ge 1 ] || [ "$(get rc "$C")" != 0 ]; } &&
    pass "control: identified by block 0 alone, the node lost its CAW path ($C)" ||
    fail "control: $C -- the suite does not reach the re-resolution"
ct_exit
