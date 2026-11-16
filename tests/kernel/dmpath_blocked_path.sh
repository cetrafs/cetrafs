#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAW moves off a BLOCKED path instead of waiting on it
#
# A path the SCSI layer has blocked -- an iSCSI session in recovery, an
# FC rport waiting out fast_io_fail_tmo -- still reads "online", so the
# cached CAW path was kept. A command sent to it is not timed while it
# waits in the quiesced queue (the 10 s CAW timeout starts at dispatch),
# so every CAW of the volume, the heartbeat's renewal among them, waited
# for the transport to give up while the other path worked (audit
# 2026-11-15 BM-49). A blocked path now ranks below every other.
#
# Two LIO loopback paths under one dm-multipath map. Once CAW has
# settled on one, that path is blocked for real (SDEV_BLOCK, its queue
# quiesced: dmpath_test_block) and failed in the map, as multipathd
# would; then a create:
#   1. completes at once, its CAW via the other path;
#   2. the block was real: the control's create waited until the test
#      unblocked the path 8 s later.
#
# DISCRIMINATION: dmpath_ignore_blocked=1 keeps the blocked path.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
P=/sys/module/cetrafs/parameters
for p in dmpath_ignore_blocked dmpath_test_block; do
    [ -e "$P/$p" ] || { skip "$p is missing"; ct_exit; }
done
ct_param_set dmpath_ignore_blocked 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
via() { sed -n 's/.*sending COMPARE AND WRITE via \([a-z]*\).*/\1/p'; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <ignore_blocked 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 mused name dev mnt mark used spare rc=0 t0 ms upid
    img="$(ct_image 600 "dbl$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="${3#/dev/}" d2="${4#/dev/}"
    name="ctdbl$1$$"
    sectors="$(blockdev --getsz "/dev/$d1")"
    m1="$(lsblk -dno MAJ:MIN "/dev/$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "/dev/$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "dbl$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    mkdir "$mnt/d"
    : >"$mnt/d/a0" || rc=1
    used="$(dmesg_since "$mark" | via | tail -1)"
    case "$used" in
    "$d1") spare="$d2" mused="$m1" ;;
    "$d2") spare="$d1" mused="$m2" ;;
    *) fail "setup: CAW is not on either path ('$used')"; ct_exit ;;
    esac
    echo "$2" >$P/dmpath_ignore_blocked
    dmsetup message "$name" 0 fail_path "$mused"
    echo "$used" >$P/dmpath_test_block
    ct_track cmd "echo -$used >$P/dmpath_test_block 2>/dev/null; true" # if the suite dies blocked
    [ "$(cat "/sys/block/$used/device/state")" = blocked ] ||
        { fail "setup: $used reads $(cat "/sys/block/$used/device/state"), not blocked"; ct_exit; }
    (sleep 8; echo "-$used" >$P/dmpath_test_block) &
    upid=$!
    mark="$(dmesg_mark)"
    t0="$(date +%s%N)"
    : >"$mnt/d/b1" || rc=1
    ms=$((($(date +%s%N) - t0) / 1000000))
    wait "$upid" || true
    dmsetup message "$name" 0 reinstate_path "$mused" || true
    echo 0 >$P/dmpath_ignore_blocked
    : >"$mnt/d/c1" || rc=1
    RES="used=$used spare=$spare ms=$ms after=$(dmesg_since "$mark" | via | tail -1) rc=$rc"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -cE 'STOPPED|SELF-FENCED' || true)"
    ct_umount "$mnt"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (blocked path kept): $C"
[ "$(field ms "$R")" -lt 3000 ] && [ "$(field after "$R")" = "$(field spare "$R")" ] &&
    pass "1: the create took $(field ms "$R") ms, its CAW via $(field spare "$R") off the blocked path" ||
    fail "1: $R"
[ "$(field rc "$R")" = 0 ] && [ "$(field stopped "$R")" = 0 ] && [ "$(field fsck_err "$R")" = 0 ] &&
    pass "creates ok, the mount ran on, fsck clean" || fail "aftermath: $R"
[ "$(field ms "$C")" -ge 6000 ] &&
    pass "2: control: on the blocked path the create waited $(field ms "$C") ms, until the unblock" ||
    fail "2: control: $C -- the block did not hold the CAW"
ct_exit
