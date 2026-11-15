#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a swap whose outcome is unknown waits out a transport error instead of ending the call
#
# A COMPARE AND WRITE whose outcome is unknown leaves its swap UNDECIDED:
# the call re-reads and retries until the region says whether it landed.
# Any error on the way -- the retry refused by a standby port, no path,
# a re-read that fails, -EINTR from a killed wait for a path -- ended the
# call, and an undecided call that ends stops the mount: one multipath
# failover stopped a node, and every host fails over together (audit
# 2026-11-15 M-21). Now the call waits, backing off, and the next fresh
# read judges; only the lease (a fenced mount writes nothing) or a window
# past it end the wait.
#
# Staged on two LIO loopback disks under a dm multipath map, a real CAW:
# caw_fail_path_once makes a create's CAW an unknown outcome that did not
# land, and caw_not_ready_count=6 then refuses its retries -- four (every
# try of one CAW over the paths) and two more:
#   the create succeeds, at least one wait was taken, the mount did not
#   stop, the file is there after a remount, fsck clean.
#
# DISCRIMINATION: cas_undecided_wait_off=1: the refused retry ends the
# undecided call and the mount stops.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in caw_not_ready_count caw_fail_path_once cas_undecided_wait_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set caw_not_ready_count 0
ct_param_set caw_fail_path_once 0
ct_param_set cas_undecided_wait_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0

# <tag> <wait_off 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark rc=0 n0 left there
    img="$(ct_image 600 "cuw$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="$3" d2="$4"
    name="ctcuw$1$$"
    sectors="$(blockdev --getsz "$d1")"
    m1="$(lsblk -dno MAJ:MIN "$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "cuw$1")"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    PROC="$(ct_procdir "$dev")"
    mkdir "$mnt/d"
    sync
    n0="$(sed -n 's/^cas_undecided_naps: //p' "$PROC/info")"
    mark="$(dmesg_mark)"
    echo "$2" >$P/cas_undecided_wait_off
    echo 6 >$P/caw_not_ready_count
    echo 1 >$P/caw_fail_path_once
    : >"$mnt/d/f" 2>/dev/null || rc=1
    left="$(cat $P/caw_not_ready_count)$(cat $P/caw_fail_path_once)"
    echo 0 >$P/caw_not_ready_count
    echo 0 >$P/caw_fail_path_once
    echo 0 >$P/cas_undecided_wait_off
    RES="rc=$rc left=$left naps=$(($(sed -n 's/^cas_undecided_naps: //p' "$PROC/info") - n0))"
    RES="$RES undecided=$(dmesg_since "$mark" | grep -c 'has not landed' || true)"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$mnt" 2>/dev/null || umount -l "$mnt"
    there=0
    if [ "$2" = 0 ]; then
        ct_mount "$dev" "$mnt"
        [ -e "$mnt/d/f" ] && there=1
        ct_umount "$mnt"
    fi
    RES="$RES there=$there fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round c 1
C="$RES"
log "control (an undecided swap ends on the error): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get left "$R")" = 0N ] && [ "$(get undecided "$R")" -ge 1 ] ||
    { fail "setup: the create's swap never went undecided, or the refusals were not spent ($R)"; ct_exit; }
[ "$(get rc "$R")" = 0 ] && [ "$(get naps "$R")" -ge 1 ] && [ "$(get stopped "$R")" = 0 ] &&
    [ "$(get there "$R")" = 1 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "the undecided create waited $(get naps "$R") time(s) through the refusals and succeeded; no stop; fsck clean" ||
    fail "$R"
[ "$(get undecided "$C")" -ge 1 ] && [ "$(get stopped "$C")" -ge 1 ] &&
    pass "control: ending the undecided call on the refusal stopped the mount" ||
    fail "control: no stop ($C) -- the suite does not reach an undecided call's error exit"
ct_exit
