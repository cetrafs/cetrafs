#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAW path whose last block is being written is still identified, not refused as another device
#
# A path under a dm multipath map is identified by block 0 and by the
# device's LAST block, read through the path and through the map and
# compared. The last block is a data block a peer may be writing: three
# immediate re-reads gave up inside one write in flight, and every path
# was refused as "not 1:1" -- no CAW, the resolution failed (audit
# 2026-11-22 N-35). It is now re-read with the tear backoff, and only a
# mismatch stable on both sides is an answer.
#
# Two LIO paths, ALUA, under a multipath map; the port in use demoted,
# so the next CAW re-resolves a path, while the last block reads changed
# on each of its first four reads (dmpath_last_hot=4):
#   1. the re-resolution identified the other path;
#   2. creates after it succeed, and the mount runs on.
#
# DISCRIMINATION: dmpath_last_quick=1 (as before): three immediate tries,
# every path refused as not 1:1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in dmpath_last_hot dmpath_last_quick; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set dmpath_last_hot 0
ct_param_set dmpath_last_quick 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CT_LIO_ALUA=1
via() { sed -n 's/.*sending COMPARE AND WRITE via \([a-z]*\).*/\1/p'; }
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <quick 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark used rc=0 i
    img="$(ct_image 600 "dlbh$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="${3#/dev/}" d2="${4#/dev/}"
    [ "$(cat "/sys/block/$d1/device/dh_state")" = alua ] || { skip "scsi_dh_alua did not attach"; ct_exit; }
    name="ctdlbh$1$$"
    sectors="$(blockdev --getsz "/dev/$d1")"
    m1="$(lsblk -dno MAJ:MIN "/dev/$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "/dev/$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "dlbh$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    : >"$mnt/a0" || rc=1
    used="$(dmesg_since "$mark" | via | tail -1)"
    [ -n "$used" ] || { fail "setup: no CAW path was resolved"; ct_exit; }
    echo "$2" >$P/dmpath_last_quick
    echo 4 >$P/dmpath_last_hot
    mark="$(dmesg_mark)"
    ct_lio_alua "$used" 1 || { fail "setup: could not demote $used"; ct_exit; }
    for i in 1 2 3; do : >"$mnt/b$i" 2>/dev/null || rc=1; done
    sleep 1
    echo 0 >$P/dmpath_last_hot
    echo 0 >$P/dmpath_last_quick
    RES="used=$used rc=$rc after=$(dmesg_since "$mark" | via | tail -1)"
    RES="$RES not1to1=$(dmesg_since "$mark" | grep -c 'last block differs from the mapped device' || true)"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED\|SELF-FENCED' || true)"
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
}

round c 1
C="$RES"
log "control (three quick tries): $C"
round f 0
R="$RES"
log "fixed: $R"
[ -n "$(get after "$R")" ] && [ "$(get after "$R")" != "$(get used "$R")" ] && [ "$(get not1to1 "$R")" = 0 ] &&
    pass "1: the re-resolution identified $(get after "$R") through a last block being written" || fail "1: $R"
[ "$(get rc "$R")" = 0 ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "2: creates after the path event succeeded; the mount runs on" || fail "2: $R"
[ "$(get not1to1 "$C")" -ge 1 ] && { [ "$(get stopped "$C")" -ge 1 ] || [ "$(get rc "$C")" != 0 ]; } &&
    pass "control: three quick tries refused the paths as not 1:1 ($C)" ||
    fail "control: $C -- the suite does not reach the last-block compare"
ct_exit
