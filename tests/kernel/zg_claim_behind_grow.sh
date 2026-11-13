#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group claim on a node behind a peer's grow recounts over the device's layout
#
# A claim recounts the claimed Zone Group's free-count aggregate from its
# members' bitmaps (cetrafs_zg_reconcile_free_counts()), over the layout
# this node has published. A node that has not caught up with a peer's
# grow does not know a Block Group the grow added -- and if the previous
# owner claimed that group into this Zone Group, the recount leaves its
# whole free count out of the aggregate. Seen in the gate as
# grow_live_owned_race.sh's fsck: "ZG1 aggregate free_data_blocks 241 !=
# 131051 actually free in its Block Groups", when the claim landed before
# the publish it was meant to land inside.
#
# The fix catches the layout up with the device after the claim's swap
# and before the recount.
#
# One node, playing the peer itself (grow_live_owned_race.sh's staging):
# the grow is committed with grow_skip_local_publish and this node's
# heartbeat refresh is off, so it stays behind; the new Block Group is
# recorded as Zone Group 1's. A write then claims Zone Group 1.
#
# The verdict is the in-core aggregate in procfs, read right after the
# claim. fsck cannot be the verdict here: a Zone Group short by exactly
# an untouched grown group is also what an interrupted grow leaves, and
# fsck accepts that as a note (image/fsck_grow_window.sh). It is still
# required clean in the main round.
#
# DISCRIMINATION: control zg_claim_layout_stale=1 skips the catch-up; the
# aggregate then holds one group's worth.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in zg_claim_layout_stale grow_skip_local_publish layout_refresh_hb_off bg_release_off zg_release_hold; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"

IMG="$(ct_big_image 2400 zgbehind)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgbehind)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
ct_param_set zg_claim_layout_stale 0
# The heartbeat hands an empty Block Group back, and the new one is
# empty: its hand-back recounts and hides the loss. Held for the suite.
ct_param_set bg_release_off 1
ct_param_set zg_release_hold 1

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
zg_owner() { grep -oP "^\s+zg $1: owner=\K\S+" "$(ct_procdir "$DEV")/info"; }

# <tag> <stale 0|1>
round() {
    local tag="$1" out newid
    ct_mkfs "$DEV" -s 1200M -b 512 -z 2 -J 0 -N 1024 -f >/dev/null
    for bg in $(ct_bgs_of_zg "$DEV" 0); do "$BG_POKE" "$DEV" "$bg" 0 fill-bitmap >/dev/null; done
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    [ "$(zg_owner 1)" = none ] || { fail "$tag: setup: Zone Group 1 is already owned at mount"; ct_umount "$MNT"; return 0; }
    ct_param_set layout_refresh_hb_off 1
    newid="$(info block_group_count)"
    ct_param_set grow_skip_local_publish 1
    out="$(ct_growfs "$DEV" -s 1800M 2>&1)" || { fail "$tag: setup: the grow failed: $(tail -2 <<<"$out")"; ct_umount "$MNT"; return 0; }
    ct_param_set grow_skip_local_publish 0
    [ "$(info block_group_count)" = "$newid" ] ||
        { fail "$tag: setup: this node caught up with the grow on its own"; ct_umount "$MNT"; return 0; }
    "$BG_POKE" "$IMG" "$newid" --owner 1 >/dev/null || { fail "$tag: setup: could not record BG$newid as Zone Group 1's"; ct_umount "$MNT"; return 0; }
    sync
    echo 3 >/proc/sys/vm/drop_caches

    ct_param_set zg_claim_layout_stale "$2"
    dd if=/dev/zero of="$MNT/w" bs=4096 count=16 conv=fsync status=none # claims Zone Group 1
    ct_param_set zg_claim_layout_stale 0
    ct_param_set layout_refresh_hb_off 0
    [ "$(zg_owner 1)" = 0 ] || { fail "$tag: setup: the write did not claim Zone Group 1"; ct_umount "$MNT"; return 0; }
    pass "$tag: setup: Zone Group 1 claimed by a node behind the grow that gave it BG$newid"
    local agg
    agg="$(grep -oP "^\s+zg 1: .*free_data_blocks=\K[0-9]+" "$(ct_procdir "$DEV")/info")"
    if [ "$2" = 1 ]; then
        [ "$agg" -le 131067 ] &&
            pass "$tag: without the catch-up the aggregate holds one group's worth ($agg)" ||
            fail "$tag: without the catch-up the aggregate still counts BG$newid ($agg) -- the control did not reproduce"
    else
        [ "$agg" -gt 131067 ] && pass "$tag: the aggregate counts both groups ($agg)" ||
            fail "$tag: the aggregate is $agg, one group's worth -- BG$newid was left out"
    fi
    ct_umount "$MNT"
    local frc=0
    out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    [ "$2" = 1 ] && return 0 # fsck accepts the control's lag as an interrupted grow's (above)
    [ "$frc" = 0 ] && pass "$tag: fsck clean" || fail "$tag: fsck rc=$frc: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
}

round control 1
round main 0
ct_exit
