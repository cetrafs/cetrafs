#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a late landing judged at the next attempt's start is reported image-only on an unstamped region
#
# A compare-and-write that timed out is judged by re-reading the region:
# at the timeout, after a MISCOMPARE, and -- when it lands after the
# timeout's re-read -- at the start of the next attempt. A match of bytes
# on a region without a stamp does not prove the swap was ours: a peer's
# swap building the same bytes reads the same (the inode allocator takes
# the lowest free bit, B-4), so the allocator is told (image_only) and
# takes another number. The three judges were three copies, and the
# attempt-start one never told it (audit 2026-11-22 N-66). They are one
# now (cetrafs_cas_judge_region()).
#
# Needs a real CAW: a LIO loopback target over the image. Unstamped
# (cas_stamp_off=1), the create's inode-bitmap swap times out and lands
# after the timeout's re-read (cas_late_image_once):
#   setup: the timeout re-read found the pre-image, and the next attempt
#     found the swap landed;
#   1. the create got a number past the one the swap claimed, and info
#      counts the abandoned bit;
#   2. creates after it go on; fsck is clean.
#
# DISCRIMINATION: cas_late_judge_exact=1 (the attempt-start judge as
# before): the create takes the claimed number itself, nothing abandoned.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cas_late_image_once cas_late_judge_exact cas_stamp_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt clio)"
ct_track mnt "$MNT"
ct_param_set cas_late_image_once 0
ct_param_set cas_late_judge_exact 0
ct_param_set cas_stamp_off 0
ct_param_set scrub 0
WHY="$(ct_tmp clio-why)"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <exact 0|1> -> RES
round() {
    local img disk proc a b c n0 n1 mark
    img="$(ct_image 560 "clio$1")"
    disk="$(ct_lio_disks "$img" 1 2>"$WHY")" || { RES="nolio"; return; }
    ct_mkfs_small "$disk" >/dev/null
    ct_mount "$disk" "$MNT"
    proc="$(ct_procdir "$disk")"
    touch "$MNT/a"
    a="$(stat -c %i "$MNT/a")"
    n0="$(sed -n 's/^ibmap_abandoned: //p' "$proc/info")"
    echo "$2" >$P/cas_late_judge_exact
    echo 1 >$P/cas_stamp_off
    mark="$(dmesg_mark)"
    echo 1 >$P/cas_late_image_once
    touch "$MNT/b"
    echo 0 >$P/cas_late_image_once
    echo 0 >$P/cas_stamp_off
    echo 0 >$P/cas_late_judge_exact
    b="$(stat -c %i "$MNT/b")"
    touch "$MNT/c"
    c="$(stat -c %i "$MNT/c")"
    n1="$(sed -n 's/^ibmap_abandoned: //p' "$proc/info")"
    RES="a=$a b=$b c=$c abandoned=$((n1 - n0))"
    RES="$RES pre=$(dmesg_since "$mark" | grep -c 'command timed out and has not landed' || true)"
    RES="$RES late=$(dmesg_since "$mark" | grep -c 'the timed-out command landed late -- taking it as done$' || true)"
    RES="$RES miscompare=$(dmesg_since "$mark" | grep -c 'region changed after a timed-out command' || true)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$disk" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
[ "$RES" = nolio ] && { skip "$(cat "$WHY")"; ct_exit; }
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (exact): $C"
[ "$(get pre "$R")" -ge 1 ] && [ "$(get late "$R")" -ge 1 ] && [ "$(get late "$C")" -ge 1 ] ||
    { fail "setup: the swap was not judged at the next attempt's start: $R / $C"; ct_exit; }
A="$(get a "$R")"
[ "$(get b "$R")" -gt $((A + 1)) ] && [ "$(get abandoned "$R")" = 1 ] &&
    pass "1: the create got $(get b "$R"), past the number the late swap claimed ($((A + 1))); counted" || fail "1: $R"
[ "$(get c "$R")" -gt "$(get b "$R")" ] && [ "$(get fsck_err "$R")" = 0 ] && pass "2: later creates go on; fsck clean" ||
    fail "2: $R"
[ "$(get b "$C")" = $(($(get a "$C") + 1)) ] && [ "$(get abandoned "$C")" = 0 ] &&
    pass "control: judged exact, the create took the claimed number itself ($C)" ||
    fail "control: $C -- the attempt-start judge was not what decided"
ct_exit
