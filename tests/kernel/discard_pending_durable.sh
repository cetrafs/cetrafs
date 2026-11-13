#!/usr/bin/env bash
# a hand-back discard of unknown outcome keeps its Block Group out of use across an unmount and a takeover
#
# A hand-back discard that fails with an UNKNOWN outcome (a timeout, a
# path failure) may still execute, so the emptied group must take no data
# until a later discard of it has a known outcome
# (discard_unknown_outcome.sh, round C). That was kept in memory only: an
# unmount, a crash, or a node taking the Zone Group over lost it, and the
# next mount allocated in the group while the old UNMAP could still land
# and destroy the new data.
#
# Format 0x000A records it on the device, CETRAFS_BG_FLAG_DISCARD_PENDING,
# set by compare-and-swap before the hand-back gives up on the group,
# cleared only by the release that hands it back after a known-outcome
# discard. The mount and every Zone Group claim load it before deriving
# which groups this node may allocate from.
#
# Block Group 0 is padded full (it holds the root and never empties);
# 96 MiB written into group 1 and deleted; every discard fails as a
# transport error, so the hand-back flags group 1.
#   remount:  unmounted with the discard outstanding, mounted again with
#             discards still failing; an 8 MiB write must not be placed
#             in group 1.
#   takeover: the same, but the Zone Group is left owned by a dead peer,
#             so the mount steals it -- as a surviving node takes over a
#             crashed one's.
# Then discards work again: the group is handed back, the flag clears on
# the device, fsck is clean.
#
# DISCRIMINATION: discard_pending_ignore=1 (the owned-bit derivation
# ignores the flag, as with an in-memory-only mark lost at unmount): the
# write lands in group 1, and fsck reports a flagged group holding data.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in discard_fail_unknown discard_pending_ignore; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
BGPOKE="$(ct_helper bg_poke)"
ZGPOKE="$(ct_helper zg_poke)"

IMG="$(ct_big_image 1200 dpdur)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dpdur)"
ct_track mnt "$MNT"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
PROC="$(ct_procdir "$DEV")"
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
flags1() { "$BGPOKE" "$IMG" 1 --dump | sed -n 's/.*flags=\([0-9]*\).*/\1/p'; }
bg1() {
    "$BGPOKE" "$IMG" 1 --dump | sed -n 's/.*start_block=\([0-9]*\).*off_data_region=\([0-9]*\).*data_block_count=\([0-9]*\).*/\1 \2 \3/p' |
        awk '{ print $1 + $2, $1 + $2 + $3 }'
}
# in_bg1 <file>: does any extent of the file lie in group 1's data region?
in_bg1() {
    local lo hi
    read -r lo hi <<<"$(bg1)"
    filefrag -v -b4096 "$1" | awk -F: -v lo="$lo" -v hi="$hi" '$1 ~ /^ *[0-9]+$/ {
        split($3, p, "[.]+"); if (p[2] + 0 >= lo && p[1] + 0 < hi) f = 1 } END { exit !f }'
}
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }

# stage: group 1 emptied with its hand-back discard outstanding, unmounted.
stage() {
    local free mark i
    ct_param_set discard_fail_unknown 0
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    free="$("$BGPOKE" "$DEV" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    fallocate -l $(((free - 256) * 4096)) "$MNT/pad"
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    mark="$(dmesg_mark)"
    ct_param_set discard_fail_unknown 1000000
    rm -rf "$MNT/bulk"
    sync
    wait_for 30 "dmesg_since '$mark' | grep -q 'hand-back discard failed and may still execute'" ||
        { fail "$1 setup: no hand-back discard failed"; return 1; }
    ct_umount "$MNT"
    [ $(( $(flags1) & 2 )) = 2 ] && pass "$1: the outstanding discard is on the device (BG1 flags $(flags1))" ||
        { fail "$1: unmounted with the discard outstanding, and BG1's descriptor does not say so (flags $(flags1))"; return 1; }
}

# round <tag> <takeover 0|1> <ignore 0|1>
round() {
    local tag="$1" peer out frc=0 mark
    stage "$tag" || return 0
    if [ "$2" = 1 ]; then
        set_stale_window "$TEST_STALE_SECS"
        peer=7
        "$ZGPOKE" "$IMG" 0 "$peer" >/dev/null
        poke_dead_peer "$IMG" "$peer" d7
        wait_out_stale_window
    fi
    ct_param_set discard_pending_ignore "$3"
    ct_mount "$DEV" "$MNT" # discards still failing
    if [ "$2" = 1 ]; then
        [ "$(sed -n 's/^\s*zg 0: owner=\([0-9]*\).*/\1/p' "$PROC/info")" != "$peer" ] ||
            { fail "$tag setup: the mount did not take Zone Group 0 over from the dead peer"; ct_param_set discard_pending_ignore 0; ct_umount "$MNT"; return 0; }
    fi
    dd if=/dev/urandom of="$MNT/w" bs=1M count=8 conv=fsync status=none 2>/dev/null || true
    ct_param_set discard_pending_ignore 0
    if [ "$3" = 1 ]; then
        [ -e "$MNT/w" ] && in_bg1 "$MNT/w" &&
            pass "$tag: with the flag ignored the write was placed in the group an UNMAP may still land on" ||
            fail "$tag: with the flag ignored the write still stayed out of group 1 -- the control proves nothing"
        ct_param_set discard_fail_unknown 0
        ct_umount "$MNT"
        out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
        [ "$frc" != 0 ] && grep -q "discard outstanding but" <<<"$out" &&
            pass "$tag: and fsck reports the flagged group holding data" ||
            fail "$tag: fsck does not see the flagged group holding data (rc=$frc)"
        return 0
    fi
    [ "$(info discard_pending_bgs)" -ge 1 ] && pass "$tag: the mount knows the group's discard is outstanding" ||
        fail "$tag: the mount lost the outstanding discard"
    if [ -e "$MNT/w" ] && in_bg1 "$MNT/w"; then
        fail "$tag: a write was placed in group 1, where the outstanding UNMAP may still land"
    else
        pass "$tag: nothing written lands in the flagged group"
    fi
    rm -f "$MNT/w"
    mark="$(dmesg_mark)"
    ct_param_set discard_fail_unknown 0 # discards work again
    wait_for 60 "dmesg_since '$mark' | grep -q 'handed back from ZG'" ||
        fail "$tag: the group was never handed back once discards worked"
    ct_umount "$MNT"
    [ $(( $(flags1) & 2 )) = 0 ] && pass "$tag: the release cleared the flag on the device" ||
        fail "$tag: BG1 still flagged after its release (flags $(flags1))"
    out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    [ "$frc" = 0 ] && pass "$tag: fsck clean" || fail "$tag: fsck rc=$frc: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
}

round control 0 1
round remount 0 0
round takeover 1 0
ct_exit
