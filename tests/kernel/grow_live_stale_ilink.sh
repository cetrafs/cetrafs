#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow that adds no inodes clears the inode link an interrupted grow left, live and offline
#
# A grow that adds inodes links its new inode segment from the table's
# tail before it publishes. Interrupted there, the link stays, pointing
# past the published end -- which mount accepts as a grow in progress.
# Retried WITHOUT new inodes, the grow lays its Block Groups over the
# place the link names and never touches the link: live, the commit's
# own layout check then refused every such grow; offline, the volume
# stopped mounting, the link now "inside the volume" (audit 2026-11-15
# F-65). Both now clear the stale link before they publish.
#
# Each round: a first live grow adds an inode segment (so later grows
# link from a tail); a second, adding inodes, is stopped after its
# links (grow_stop_after=2); it is then retried adding none (-N at the
# current count).
#   live:    the retry succeeds, the tail's link is gone, a remount and
#            fsck are clean;
#   offline: the same retry unmounted; then mount and fsck are clean.
#
# DISCRIMINATION: grow_keep_stale_ilink=1 (live) -- the retry is refused;
# CETRAFS_GROWFS_TEST_KEEP_STALE_ILINK=1 (offline) -- the mount is refused.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/grow_keep_stale_ilink ] || { skip "grow_keep_stale_ilink is missing"; ct_exit; }
SEGPOKE="$(ct_helper seg_poke)"
ct_param_set grow_stop_after 0
ct_param_set grow_keep_stale_ilink 0

# Segments on the inode chain, walked to its end: 1 after the first grow,
# 2 while the interrupted grow's link is there.
chain_len() { SEG_POKE_CHAIN=inode "$SEGPOKE" "$1" dump 2>/dev/null | sed -n 's/.* segs=//p'; }

# round <live|offline> <control 0|1> -> "<retry rc> <chain segments> <mount ok|refused> <fsck rc>"
round() {
    local dev mnt out rc=0 mnt_ok=refused frc=0 nx
    dev="$(ct_big_dev 2500 "gsil$1$2")"
    mnt="$(ct_mnt "gsil$1$2")"
    ct_track mnt "$mnt"
    ct_mkfs "$dev" -s 600M -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$mnt"
    out="$(ct_growfs "$dev" -s 1200M -N 1300 2>&1)" || { echo "setup-grow1 $(tail -3 <<<"$out" | tr " \n" "_|")"; return; }
    ct_param_set grow_stop_after 2
    ct_growfs "$dev" -s 1800M -N 1600 >/dev/null 2>&1 && { echo "setup-notstopped"; return; }
    [ "$(cat /sys/module/cetrafs/parameters/grow_stop_after)" = 0 ] || { echo "setup-notreached"; return; }
    [ "$(chain_len "$dev")" = 2 ] || { echo "setup-nolink"; return; }
    if [ "$1" = live ]; then
        ct_param_set grow_keep_stale_ilink "$2"
        ct_growfs "$dev" -s 2400M -N 1300 >/dev/null 2>&1 || rc=$?
        ct_param_set grow_keep_stale_ilink 0
        ct_umount "$mnt"
    else
        ct_umount "$mnt"
        if [ "$2" = 1 ]; then
            CETRAFS_GROWFS_TEST_KEEP_STALE_ILINK=1 ct_growfs "$dev" -s 2400M -N 1300 >/dev/null 2>&1 || rc=$?
        else
            ct_growfs "$dev" -s 2400M -N 1300 >/dev/null 2>&1 || rc=$?
        fi
    fi
    nx="$(chain_len "$dev")"
    if mount -t cetrafs "$dev" "$mnt" 2>/dev/null; then
        mnt_ok=ok
        umount "$mnt"
    fi
    out="$(ct_fsck "$dev" 2>&1)" || frc=$?
    [ "$frc" = 0 ] || grep -m2 ERR <<<"$out" >&2 || true
    echo "$rc ${nx:-none} $mnt_ok $frc"
}

for M in live offline; do
    read -r RC NX MO FRC <<<"$(round "$M" 0)"
    case "$RC" in setup-*) fail "$M setup: $RC $NX"; continue ;; esac
    [ "$RC" = 0 ] && [ "$NX" = 1 ] && [ "$MO" = ok ] && [ "$FRC" = 0 ] &&
        pass "$M: the retry without inodes succeeds, the stale link is gone, mount and fsck are clean" ||
        fail "$M: retry rc=$RC, inode chain $NX segment(s), mount $MO, fsck rc=$FRC"
    read -r RC NX MO FRC <<<"$(round "$M" 1)"
    case "$RC" in setup-*) fail "$M control setup: $RC"; continue ;; esac
    { [ "$RC" != 0 ] || [ "$MO" = refused ]; } &&
        pass "$M control: with the link kept the volume cannot be grown or mounted (retry rc=$RC, mount $MO)" ||
        fail "$M control: retry rc=$RC, mount $MO -- the stale link did no harm; the suite cannot tell"
done
ct_exit
