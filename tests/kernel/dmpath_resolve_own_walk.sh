#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# many multipath path resolutions inside one system call still find a path
#
# Resolving which SCSI path carries a dm volume's COMPARE AND WRITE
# looks up the map's slaves in sysfs, and that lookup ran inside the
# caller's own path walk -- a CAS runs inside open(2), mkdir(2) and the
# rest. A nested walk inherits the outer one's symlink count and hands
# its own back (fs/namei.c), so after five or six resolutions in one
# system call every lookup failed ELOOP and the volume had "no path"
# until that call ended; an undecided swap then waited out its whole
# window on a path that was there all along. The lookup is now a walk
# of its own.
#
# Staged on two LIO loopback disks under a dm multipath map, a real CAW:
# caw_fail_path_once makes a create's CAW an unknown outcome, and
# caw_not_ready_count=20 then refuses five rounds of retries -- each one a
# path resolution, all inside the one creat(2):
#   the create succeeds; no "no path" was reported; fsck clean.
#
# DISCRIMINATION: dmpath_nested_walk=1 (the lookup inside the caller's
# walk): "no path" for the rest of the call.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in caw_not_ready_count caw_fail_path_once dmpath_nested_walk; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set caw_not_ready_count 0
ct_param_set caw_fail_path_once 0
ct_param_set dmpath_nested_walk 0
ct_param_set scrub 0
ct_param_set auto_defrag 0

# <tag> <nested 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark rc=0 left
    img="$(ct_image 600 "drw$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="$3" d2="$4"
    name="ctdrw$1$$"
    sectors="$(blockdev --getsz "$d1")"
    m1="$(lsblk -dno MAJ:MIN "$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "drw$1")"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    mkdir "$mnt/d"
    sync
    mark="$(dmesg_mark)"
    echo "$2" >$P/dmpath_nested_walk
    echo 20 >$P/caw_not_ready_count
    echo 1 >$P/caw_fail_path_once
    : >"$mnt/d/f" 2>/dev/null || rc=1
    left="$(cat $P/caw_not_ready_count)"
    echo 0 >$P/caw_not_ready_count
    echo 0 >$P/caw_fail_path_once
    echo 0 >$P/dmpath_nested_walk
    RES="rc=$rc left=$left resolved=$(dmesg_since "$mark" | grep -c 'sending COMPARE AND WRITE via' || true)"
    RES="$RES nopath=$(dmesg_since "$mark" | grep -c 'no path of' || true)"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$mnt" 2>/dev/null || umount -l "$mnt"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round c 1
C="$RES"
log "control (the lookup inside the caller's walk): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get left "$R")" = 0 ] && [ "$(get resolved "$R")" -ge 10 ] ||
    { fail "setup: the create did not resolve paths many times over ($R)"; ct_exit; }
[ "$(get rc "$R")" = 0 ] && [ "$(get nopath "$R")" = 0 ] && [ "$(get stopped "$R")" = 0 ] &&
    [ "$(get fsck_err "$R")" = 0 ] &&
    pass "$(get resolved "$R") path resolutions inside one creat(2), never \"no path\"; the create succeeded; fsck clean" ||
    fail "$R"
[ "$(get nopath "$C")" -ge 1 ] &&
    pass "control: inside the caller's walk the volume had \"no path\" $(get nopath "$C") time(s)" ||
    fail "control: no \"no path\" ($C) -- the suite does not reach the nested lookup's limit"
ct_exit
