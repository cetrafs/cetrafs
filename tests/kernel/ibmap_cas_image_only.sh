#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an inode number claimed by a swap of unknown outcome is not used
#
# A compare-and-write whose outcome is unknown (a timeout) is settled by
# re-reading the region: finding the swap's post-image there was taken
# as success. The inode allocator's mutator takes the lowest free bit and
# carries no writer identity, so a peer that read the same region builds
# the same bytes -- its swap reads as ours, and both creators hold one
# virgin number: two names, one record (audit 2026-11-14 B-4). A success
# decided from the image alone is now reported to the allocator, which
# leaves that bit set and takes another, stamping the number's
# never-written record dead so the orphan pass reclaims it (review F-11).
#
# Needs a real CAW: a LIO loopback target over the image. TEST ONLY
# cas_judged_timeout_once makes the next inode-bitmap swap execute and
# then report a timeout -- the case a peer's identical swap is
# indistinguishable from.
#   1. the create after it gets a number past the one that swap claimed,
#      and info counts the abandoned bit;
#   2. creates after it go on normally; fsck reports no error.
#   3. the abandoned number's record is stamped dead: two scrub cycles
#      run over it, meet no never-written record (which stops a cycle's
#      frees, review F-11) and count no damage; fsck finds no
#      never-written record.
#
# DISCRIMINATION: ibmap_trust_image=1 (the old verdict): the create gets
# the claimed number itself. ibmap_abandon_no_stamp=1 (the record left
# zeros): every cycle of 3 meets it, and fsck reports it never written.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cas_judged_timeout_once ibmap_trust_image; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt ibci)"
ct_track mnt "$MNT"
ct_param_set cas_judged_timeout_once 0
ct_param_set ibmap_trust_image 0
ct_param_set ibmap_abandon_no_stamp 0
# the scrub, quick: set before each mount (the interval is read there)
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
WHY="$(ct_tmp ibci-why)"

# <trust 0|1> [<no stamp 0|1>] -> "a=<ino> b=<ino> c=<ino> abandoned=<delta> cycles=<n> damage=<n> unknown=<n> unwritten=<0|1> fsck=<clean|ERR>"
round() {
    local img disk proc a b c n0 n1 out
    img="$(ct_image 560 "ibci$1")"
    disk="$(ct_lio_disks "$img" 1 2>"$WHY")" || { echo "nolio"; return; }
    ct_mkfs_small "$disk" >/dev/null
    ct_mount "$disk" "$MNT"
    proc="$(ct_procdir "$disk")"
    touch "$MNT/a"
    a="$(stat -c %i "$MNT/a")"
    n0="$(sed -n 's/^ibmap_abandoned: //p' "$proc/info")"
    echo "${2:-0}" >/sys/module/cetrafs/parameters/ibmap_abandon_no_stamp
    echo "$1" >/sys/module/cetrafs/parameters/ibmap_trust_image
    echo 1 >/sys/module/cetrafs/parameters/cas_judged_timeout_once
    touch "$MNT/b"
    echo 0 >/sys/module/cetrafs/parameters/cas_judged_timeout_once
    echo 0 >/sys/module/cetrafs/parameters/ibmap_trust_image
    b="$(stat -c %i "$MNT/b")"
    touch "$MNT/c"
    c="$(stat -c %i "$MNT/c")"
    n1="$(sed -n 's/^ibmap_abandoned: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/ibmap_abandon_no_stamp
    local c0 d0 c1 d1 u0 u1 dl=$((SECONDS + 90))
    c0="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    d0="$(sed -n 's/^corruptions: //p' "$proc/info")"
    u0="$(sed -n 's/^scrub_unknown_records: //p' "$proc/info")"
    while [ "$(sed -n 's/^scrub_cycles: //p' "$proc/info")" -lt $((c0 + 2)) ] && [ "$SECONDS" -lt "$dl" ]; do sleep 1; done
    c1="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    d1="$(sed -n 's/^corruptions: //p' "$proc/info")"
    u1="$(sed -n 's/^scrub_unknown_records: //p' "$proc/info")"
    ct_umount "$MNT"
    local uw=0
    out="$(ct_fsck "$disk" 2>&1 || true)"
    grep -q "record was never written" <<<"$out" && uw=1
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    echo "a=$a b=$b c=$c abandoned=$((n1 - n0)) cycles=$((c1 - c0)) damage=$((d1 - d0)) unknown=$((u1 - u0)) unwritten=$uw fsck=$out"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
[ "$R" = nolio ] && { skip "$(cat "$WHY")"; ct_exit; }
log "abandoning: $R"
C="$(round 1)"
log "control (trusting the image): $C"
A="$(get a "$R")"
[ "$(get b "$R")" -gt "$((A + 1))" ] && [ "$(get abandoned "$R")" = 1 ] &&
    pass "1: the create got $(get b "$R"), past the number the unknown swap claimed ($((A + 1))); counted" ||
    fail "1: $R"
[ "$(get c "$R")" -gt "$(get b "$R")" ] && [ "$(get fsck "$R")" = clean ] && pass "2: later creates go on; fsck clean" ||
    fail "2: $R"
[ "$(get b "$C")" = "$(($(get a "$C") + 1))" ] && [ "$(get abandoned "$C")" = 0 ] &&
    pass "control: trusting the image, the create took the claimed number itself" ||
    fail "control: the suite did not reach an image-only success ($C)"
[ "$(get cycles "$R")" -ge 2 ] && [ "$(get damage "$R")" = 0 ] && [ "$(get unknown "$R")" = 0 ] &&
    [ "$(get unwritten "$R")" = 0 ] &&
    pass "3: the abandoned number was stamped dead: two scrub cycles met no never-written record, no damage" ||
    fail "3: over the abandoned number: $R"
D="$(round 0 1)"
log "control (left unwritten): $D"
[ "$(get unknown "$D")" -gt 0 ] && [ "$(get unwritten "$D")" = 1 ] &&
    pass "control: left zeros, the number stopped $(get unknown "$D") scrub cycles' frees and fsck calls it never written" ||
    fail "control: the unwritten record went unseen ($D) -- the scrub did not reach it"
ct_exit
