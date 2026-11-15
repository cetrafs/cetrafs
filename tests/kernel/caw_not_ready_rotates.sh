#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAW refused NOT READY on a multipath path is re-issued on the next, never taken as unknown
#
# An active/passive array answers a command on its passive port with
# NOT READY / LOGICAL UNIT NOT READY (asc 0x04): not executed. The
# classifier read that as an UNKNOWN outcome, and the dm branch turned
# every refusal into one, so a failover sent each swap through the
# undecided machinery: 16 refusals in a row stopped the mount with no
# peer at all, and a peer CAS between the re-reads stopped it after one
# (audit 2026-11-15 M-22, N-66). Now a refusal of a path is definite: the
# swap is re-issued on the next path, and a run of them ends the call as
# a plain -EIO, nothing applied.
#
# Staged on two LIO loopback disks under a dm multipath map, a real CAW;
# caw_not_ready_count refuses the next N CAWs NOT READY (standby port):
#   A. N=3, one create: it succeeds, and no swap went undecided;
#   B. N=20, then creates: the mount does not stop; every create once the
#      refusals are spent succeeds; fsck clean;
#   S. the mount's CAS selftest (cas_selftest=1) applies an increment
#      across a refusal exactly once.
#
# DISCRIMINATION: caw_definite_as_unknown=1 (the old dm rewrite), with
# cas_undecided_wait_off=1 (an undecided swap ends on the next error, as
# then): A's create goes undecided; B stops the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in caw_not_ready_count caw_definite_as_unknown cas_undecided_wait_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set caw_not_ready_count 0
ct_param_set caw_definite_as_unknown 0
ct_param_set cas_undecided_wait_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0

# <tag> <definite_as_unknown 0|1> -> RES
round() {
    local img disks d1 d2 sectors m1 m2 name dev mnt mark ok=0 bad=0 i a_rc stopped undec left
    img="$(ct_image 600 "cnr$1")"
    disks="$(ct_lio_disks "$img" 2)" || { skip "no LIO loopback target here"; ct_exit; }
    set -- "$1" "$2" $disks
    [ $# -eq 4 ] || { fail "setup: expected two paths, got '$disks'"; ct_exit; }
    d1="$3" d2="$4"
    name="ctcnr$1$$"
    sectors="$(blockdev --getsz "$d1")"
    m1="$(lsblk -dno MAJ:MIN "$d1" | tr -d ' ')"
    m2="$(lsblk -dno MAJ:MIN "$d2" | tr -d ' ')"
    dmsetup create "$name" --table "0 $sectors multipath 0 0 1 1 round-robin 0 2 1 $m1 1000 $m2 1000" ||
        { skip "dm-multipath is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    mnt="$(ct_mnt "cnr$1")"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    dmesg_since "$mark" | grep -q "dm path: .* sending COMPARE AND WRITE via" ||
        { fail "setup: the mount found no CAW path"; ct_exit; }
    SELFTEST="$(dmesg_since "$mark" | grep -c 'refused not-ready on one path) command applied the delta exactly once' || true)"
    mkdir "$mnt/d"
    sync
    echo "$2" >$P/caw_definite_as_unknown
    echo "$2" >$P/cas_undecided_wait_off

    # A
    mark="$(dmesg_mark)"
    echo 3 >$P/caw_not_ready_count
    a_rc=0
    : >"$mnt/d/a" || a_rc=$?
    left="$(cat $P/caw_not_ready_count)"
    undec="$(dmesg_since "$mark" | grep -c 'has not landed\|timed out' || true)"
    RES="a_rc=$a_rc a_left=$left a_undecided=$undec"

    # B
    mark="$(dmesg_mark)"
    echo 20 >$P/caw_not_ready_count
    for i in $(seq 1 40); do
        if : >"$mnt/d/b$i" 2>/dev/null; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
        [ "$(cat $P/caw_not_ready_count)" = 0 ] && [ "$ok" -ge 5 ] && break
    done
    left="$(cat $P/caw_not_ready_count)"
    echo 0 >$P/caw_not_ready_count
    echo 0 >$P/caw_definite_as_unknown
    echo 0 >$P/cas_undecided_wait_off
    stopped="$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    local post=0
    for i in 1 2 3; do : >"$mnt/d/post$i" 2>/dev/null && post=$((post + 1)); done
    RES="$RES b_left=$left b_ok=$ok b_failed=$bad stopped=$stopped post=$post"
    umount "$mnt" 2>/dev/null || umount -l "$mnt"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true) selftest=$SELFTEST"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round c 1
C="$RES"
log "control (refusals reported unknown): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get a_left "$R")" = 0 ] && [ "$(get b_left "$R")" = 0 ] ||
    { fail "setup: the injected refusals were not all consumed ($R)"; ct_exit; }
[ "$(get a_rc "$R")" = 0 ] && [ "$(get a_undecided "$R")" = 0 ] &&
    pass "A: three refusals rotated across the paths; the create succeeded and nothing went undecided" ||
    fail "A: $R"
[ "$(get stopped "$R")" = 0 ] && [ "$(get post "$R")" = 3 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "B: twenty refusals failed $(get b_failed "$R") create(s) plainly; the mount ran on; fsck clean" ||
    fail "B: $R"
[ "$(get selftest "$R")" -ge 1 ] &&
    pass "S: the CAS selftest applied an increment across a refusal exactly once" ||
    fail "S: the selftest's refusal phase did not pass on the dm mount ($R)"
[ "$(get a_undecided "$C")" -ge 1 ] && [ "$(get stopped "$C")" -ge 1 ] &&
    pass "control: with refusals reported unknown, A went undecided and B stopped the mount" ||
    fail "control: the old rewrite did not show ($C) -- the suite cannot see the classification"
ct_exit
