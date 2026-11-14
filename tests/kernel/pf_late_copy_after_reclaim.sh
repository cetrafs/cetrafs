#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a pending free that lands after the scrub reclaimed its block is dropped, not applied to the next file
#
# A node frees a block in a Zone Group a peer owns by appending
# {lba, count} to the owner's pending-free queue. If that append's
# COMPARE AND WRITE times out, the node cannot tell whether it landed and
# stops its mount -- but the command may still be queued in the fabric
# and reach the device minutes later. Meanwhile the owner's scrub sees
# the block set and referenced by nothing, reclaims it as a leak, and the
# allocator gives it to a new file. Then the late entry lands, the drain
# applies it, and the new file's block reads FREE: the next allocation
# puts a second file on it. Nothing in a {lba, count, magic} entry tells
# that copy from a live one (TODO Data safety, 2026-11-13).
#
# Format 0x000A: an entry carries its group's free_gen as the appender
# read it; the scrub raises the group's free_gen before it reclaims a
# leak there (cetrafs_bg_bump_free_gen()); the drain applies an entry
# only while the two are equal (cetrafs_apply_pending_free()).
#
# Staged on one node, the late command being an entry written to the
# queue on the device while the volume is unmounted:
#   1. a leaked block L (data_leak_poke), the scrub reclaims it -- and
#      must raise BG0's free_gen doing so;
#   2. a file B is written over L;
#   3. unmounted, the "late" entry for L goes into ZG0's queue stamped
#      with the free_gen from BEFORE the reclaim;
#   4. the mount's drain meets it.
# Main: the entry is dropped (pf_stale_drops), L stays allocated, B reads
# back intact and fsck is clean. Control (pf_ignore_stamp=1, the drain as
# it was): the entry is applied and fsck finds B's block marked FREE.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in pf_ignore_stamp scrub_interval_secs scrub_gap_secs; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"
PP="$(ct_helper pending_poke)"
BGPOKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 pflate)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pflate)"
WORK="$(ct_mnt pflatework)"
ct_track mnt "$MNT"
PROC() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
gen() { "$BGPOKE" "$IMG" 0 --dump | sed -n 's/.*free_gen=\([0-9]*\).*/\1/p'; }
# Is LBA $2 inside one of file $1's extents?
covers() {
    filefrag -v -b4096 "$1" | awk -F: -v l="$2" '$1 ~ /^ *[0-9]+$/ {
        split($3, p, "[.]+"); if (l >= p[1] + 0 && l <= p[2] + 0) f = 1 } END { exit !f }'
}

# round <tag> <ignore-stamp 0|1>
round() {
    local tag="$1" L G0 G1 R0 C0 out frc=0
    ct_param_set scrub 1
    ct_param_set scrub_interval_secs 3
    ct_param_set scrub_gap_floor_secs 1
    ct_param_set scrub_gap_secs 2
    ct_param_set hb_drain_off 1 # no drain but the mount's
    ct_param_set pf_ignore_stamp 0
    ct_mkfs_small "$DEV" -z 1 >/dev/null
    L="$("$LEAK" "$DEV" 0 40 1 | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
    [ -n "$L" ] || { fail "$tag setup: no leaked block"; return 0; }
    G0="$(gen)"

    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    R0="$(PROC scrub_reclaimed)"; C0="$(PROC scrub_cycles)"
    for _ in $(seq 1 60); do
        [ "$(PROC scrub_reclaimed)" -gt "$R0" ] && [ "$(PROC scrub_cycles)" -gt "$C0" ] && break
        sleep 1
    done
    [ "$(PROC scrub_reclaimed)" -gt "$R0" ] || { fail "$tag setup: the scrub reclaimed nothing"; ct_umount "$MNT"; return 0; }
    sync
    G1="$(gen)"
    [ "$G1" -gt "$G0" ] && pass "$tag: the scrub raised BG0's free_gen before reclaiming ($G0 -> $G1)" ||
        fail "$tag: the scrub reclaimed $L without raising BG0's free_gen ($G0 -> $G1)"

    dd if=/dev/urandom of="$MNT/B" bs=1M count=4 conv=fsync status=none
    covers "$MNT/B" "$L" || { fail "$tag setup: file B was not given the reclaimed block $L"; ct_umount "$MNT"; return 0; }
    pass "$tag setup: file B now holds the reclaimed block $L"
    md5sum <"$MNT/B" >"$WORK/B.$tag"
    ct_umount "$MNT"

    # The late command: stamped as its appender read it, before the reclaim.
    PENDING_POKE_STAMP="$G0" "$PP" "$IMG" add 0 "$L" 1 >/dev/null
    [ "$("$PP" "$IMG" dumpgen 0)" = "$L 1 $G0" ] || { fail "$tag setup: the late entry is not queued as staged"; return 0; }

    ct_param_set pf_ignore_stamp "$2"
    MARK="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT" # its drain meets the late entry
    ct_param_set pf_ignore_stamp 0
    [ -z "$("$PP" "$IMG" dump 0)" ] || fail "$tag setup: the mount's drain did not consume the late entry"
    if [ "$2" = 0 ]; then
        dmesg_since "$MARK" | grep -q "pending free \[$L +1) is stamped $G0" &&
            pass "$tag: the drain dropped the late entry for its stale stamp" ||
            fail "$tag: no stale-stamp drop for [$L +1) in the kernel log"
        echo 3 >/proc/sys/vm/drop_caches
        md5sum <"$MNT/B" | cmp -s - "$WORK/B.$tag" && pass "$tag: file B reads back intact" ||
            fail "$tag: file B changed"
    fi
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    if [ "$2" = 1 ]; then
        [ "$frc" != 0 ] && grep -qi "FREE" <<<"$out" &&
            pass "$tag: without the stamp check the late entry freed file B's block (fsck: $(grep -m1 ERR <<<"$out"))" ||
            fail "$tag: without the stamp check fsck is still clean -- the control does not reproduce"
    else
        [ "$frc" = 0 ] && pass "$tag: fsck clean" || fail "$tag: fsck rc=$frc: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
    fi
}

round control 1
round main 0
ct_exit
