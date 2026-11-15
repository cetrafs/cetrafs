#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the CAW path is the ALUA optimised one, chosen up front and again when the array fails over
#
# A dm volume's COMPARE AND WRITE went down the first path that passed
# the identity check, whatever the array said of it: an
# active/non-optimised port, where every CAW is proxied between
# controllers, as readily as the optimised one. And once chosen it was
# kept when a failover made it standby, so the next swap went there and
# was refused NOT READY before a rotation found the active port (audit
# 2026-11-15 M-23). (A port already standby at resolution refuses the
# identity check's READ, and was never chosen.) Paths are now ranked by
# their ALUA state, and a cached path the array moves to a worse state
# is re-resolved before the next swap.
#
# Staged on two LIO loopback disks under a dm multipath map, each port in
# its own ALUA target port group, a real CAW:
#   A. the port in use becomes active/non-optimised and the other
#      optimised: within dmpath_upgrade_secs the CAW moves to the
#      optimised one;
#   B. failover: the port in use goes standby, the other optimised: the
#      next swaps go to the other port, none refused;
#   creates succeed throughout; the mount does not stop; fsck clean.
#
# DISCRIMINATION: dmpath_ignore_alua=1 (every path alike): A stays on
# the non-optimised port, and B's next swap is refused on the standby one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
[ -w /sys/module/cetrafs/parameters/dmpath_ignore_alua ] || { skip "dmpath_ignore_alua is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
ct_param_set dmpath_ignore_alua 0
ct_param_set dmpath_upgrade_secs 1
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CT_LIO_ALUA=1
# LIO's own WARN on a CAW refused at a standby port (the control's B):
# the target's, not ours; everything else in dmesg still counts.
CT_DMESG_IGNORE_WARN='WARNING: drivers/target/target_core_sbc.c:[0-9]+ at compare_and_write_callback'
via() { sed -n 's/.*sending COMPARE AND WRITE via \([a-z]*\).*/\1/p'; }

# <tag> <ignore 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark first other used spare cur nxt rc=0 i
    img="$(ct_image 600 "dal$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="${3#/dev/}" d2="${4#/dev/}"
    [ "$(cat "/sys/block/$d1/device/dh_state")" = alua ] ||
        { skip "scsi_dh_alua did not attach to the LIO ports"; ct_exit; }
    name="ctdal$1$$"
    sectors="$(blockdev --getsz "/dev/$d1")"
    m1="$(lsblk -dno MAJ:MIN "/dev/$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "/dev/$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    # the slave the old choice takes: the first the walk lists
    first="$(ls -U "/sys/block/$(basename "$(readlink -f "$dev")")/slaves" | head -1)"
    if [ "$first" = "$d1" ]; then other="$d2"; else other="$d1"; fi
    echo "$2" >$P/dmpath_ignore_alua
    mnt="$(ct_mnt "dal$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    mkdir "$mnt/d"
    : >"$mnt/d/a0" || rc=1
    used="$(dmesg_since "$mark" | via | tail -1)"
    if [ "$used" = "$first" ]; then spare="$other"; else spare="$first"; fi
    # A: the port in use is demoted, the other is optimised
    ct_lio_alua "$used" 1 || { fail "setup: could not make $used non-optimised"; ct_exit; }
    mark="$(dmesg_mark)"
    sleep 1.5
    for i in 1 2 3; do : >"$mnt/d/a$i" || rc=1; done
    RES="used=$used spare=$spare a_via=$(dmesg_since "$mark" | via | tail -1)"
    # B: the array fails over: the port carrying the CAW goes standby,
    # the other optimised
    cur="$(grep -o 'a_via=[a-z]*' <<<"$RES" | cut -d= -f2)"
    cur="${cur:-$used}"
    if [ "$cur" = "$used" ]; then nxt="$spare"; else nxt="$used"; fi
    mark="$(dmesg_mark)"
    ct_lio_alua "$nxt" 0 || { fail "setup: could not make $nxt optimised"; ct_exit; }
    ct_lio_alua "$cur" 2 || { fail "setup: could not make $cur standby"; ct_exit; }
    for i in 1 2 3; do : >"$mnt/d/b$i" || rc=1; done
    RES="$RES cur=$cur nxt=$nxt b_via=$(dmesg_since "$mark" | via | tail -1)"
    RES="$RES b_refused=$(dmesg_since "$mark" | grep -c 'path not ready' || true)"
    RES="$RES rc=$rc stopped=$(dmesg_since "$mark" | grep -c STOPPED || true)"
    echo 0 >$P/dmpath_ignore_alua
    ct_umount "$mnt"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round c 1
C="$RES"
log "control (ALUA ignored): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get a_via "$R")" = "$(get spare "$R")" ] &&
    pass "A: with $(get used "$R") demoted to non-optimised, the CAW moved to the optimised $(get spare "$R")" ||
    fail "A: $R"
[ "$(get b_via "$R")" = "$(get nxt "$R")" ] && [ "$(get b_refused "$R")" = 0 ] &&
    pass "B: after the failover the next swaps went to $(get nxt "$R"), none refused" || fail "B: $R"
[ "$(get rc "$R")" = 0 ] && [ "$(get stopped "$R")" = 0 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "every create succeeded; the mount ran on; fsck clean" || fail "$R"
[ -z "$(get a_via "$C")" ] && [ "$(get b_refused "$C")" -ge 1 ] &&
    pass "control: ignoring ALUA, A stayed on the non-optimised port and B's swap was refused on the standby one" ||
    fail "control: ($C) -- the suite cannot see the ranking"
ct_exit
