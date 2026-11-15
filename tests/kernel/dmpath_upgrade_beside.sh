#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an ALUA upgrade resolves the better path beside the working one; nothing waits for it
#
# A CAW path that is not optimised is looked past every
# dmpath_upgrade_secs. The look dropped the working path first and then
# resolved, so every CAW of the volume -- the heartbeat's renewal
# included -- waited for that resolution, up to the identity READ's
# timeout, every look; for good when the "better" path reports optimal
# and does not answer (audit 2026-11-15 F-24). The better path is now
# resolved beside the working one and swapped in only once it has passed.
#
# Staged as dmpath_alua_prefers_active.sh: both ports start
# non-optimised, so CAW settles on one at that rank; then the other
# becomes optimised and every resolution takes 4 s
# (dmpath_resolve_delay_ms). A create starts the look; a second create
# half a second later, in another directory (the first holds its own
# parent's namespace lock while it waits):
#   1. completes in well under the resolution's 4 s (the working path);
#   2. once the look is done, CAW goes via the optimised port;
#   creates succeed, the mount runs on, fsck clean.
#
# DISCRIMINATION: dmpath_upgrade_drops_first=1: the second create waits
# out the resolution.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in dmpath_upgrade_drops_first dmpath_resolve_delay_ms dmpath_upgrade_secs; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set dmpath_upgrade_drops_first 0
ct_param_set dmpath_resolve_delay_ms 0
ct_param_set dmpath_upgrade_secs 1
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CT_LIO_ALUA=1
via() { sed -n 's/.*sending COMPARE AND WRITE via \([a-z]*\).*/\1/p; s/.* and \([a-z]*\) passed as .* moving CAW there.*/\1/p'; }
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <drops_first 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark used spare rc=0 bpid t0 ms
    img="$(ct_image 600 "dub$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="${3#/dev/}" d2="${4#/dev/}"
    [ "$(cat "/sys/block/$d1/device/dh_state")" = alua ] || { skip "scsi_dh_alua did not attach"; ct_exit; }
    name="ctdub$1$$"
    sectors="$(blockdev --getsz "/dev/$d1")"
    m1="$(lsblk -dno MAJ:MIN "/dev/$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "/dev/$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_lio_alua "$d1" 1 && ct_lio_alua "$d2" 1 || { fail "setup: could not make both paths non-optimised"; ct_exit; }
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "dub$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    mkdir "$mnt/d" "$mnt/e"
    : >"$mnt/d/a0" || rc=1
    used="$(dmesg_since "$mark" | via | tail -1)"
    if [ "$used" = "$d1" ]; then spare="$d2"; else spare="$d1"; fi
    ct_lio_alua "$spare" 0 || { fail "setup: could not make $spare optimised"; ct_exit; }
    echo "$2" >$P/dmpath_upgrade_drops_first
    echo 4000 >$P/dmpath_resolve_delay_ms
    sleep 1.5
    mark="$(dmesg_mark)"
    : >"$mnt/d/b1" &
    bpid=$!
    sleep 0.5
    t0="$(date +%s%N)"
    : >"$mnt/e/b2" || rc=1
    ms=$((($(date +%s%N) - t0) / 1000000))
    wait "$bpid" || rc=1
    echo 0 >$P/dmpath_resolve_delay_ms
    : >"$mnt/d/c1" || rc=1
    RES="used=$used spare=$spare second_ms=$ms after=$(dmesg_since "$mark" | via | tail -1) rc=$rc"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c STOPPED || true)"
    echo 0 >$P/dmpath_upgrade_drops_first
    ct_umount "$mnt"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round c 1
C="$RES"
log "control (dropped first): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get second_ms "$R")" -lt 1500 ] &&
    pass "1: a create during the look took $(get second_ms "$R") ms on the working path" || fail "1: $R"
[ "$(get after "$R")" = "$(get spare "$R")" ] && [ "$(get rc "$R")" = 0 ] && [ "$(get stopped "$R")" = 0 ] &&
    [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: the look then moved CAW to the optimised $(get spare "$R"); creates ok, fsck clean" || fail "2: $R"
[ "$(get second_ms "$C")" -ge 2500 ] &&
    pass "control: with the working path dropped first, the create waited $(get second_ms "$C") ms" ||
    fail "control: $C -- the suite does not reach the look"
ct_exit
