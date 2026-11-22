#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a trimmed run of unknown discard outcome stays held when its Zone Group changes hands
# ct-timeout: 300
#
# FITRIM keeps a run whose discard outcome is unknown allocated, and holds
# it from the scrub for trim_quarantine_secs (trim_unknown_quarantine.sh).
# The hold is in the memory of the node that trimmed. Its Zone Group goes
# on without that node at an unmount (it stays with the departed row for
# the next claimer), a crash or a fence, and the claimer's scrub then
# reclaimed the run on its own schedule while the UNMAP could still be
# queued (audit 2026-11-22, the N-24 residual). Whoever takes a Zone
# Group from an owner -- a peer stealing it, or this node re-attaching at
# mount -- now keeps the scrub out of the whole group for its own
# trim_quarantine_secs. This suite takes the re-attach route; a steal
# goes through the same hold (cetrafs_zg_try_claim_one()).
#
# A kept run (2048 blocks), then an immediate unmount, which drops the
# trimming node's hold, and a remount with the scrub on a 2 s cycle:
#   control: trim_quarantine_secs 1 at the remount -- the scrub reclaims
#            the run within a few cycles, so the check below can see a
#            reclaim (this is what the remount did before the fix);
#   1. trim_quarantine_secs 30: info reports a held Zone Group, and three
#      scrub cycles reclaim nothing;
#   2. once the 30 s are over the scrub reclaims the run, and fsck finds
#      no leak.
#   3. the Zone Group left UNOWNED between the unmount and the mount, as
#      fsck -r leaves one whose damaged record it rebuilt: the claim of an
#      unowned group holds it too (info, and no reclaim in three cycles).
#      Control: zg_hold_owned_only=1, the claim as before -- the scrub
#      reclaims the run at once.
#
# DISCRIMINATION (measured with the hold removed): check 1 fails, the
# scrub reclaiming the run in its first cycles after the remount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
for p in discard_fail_unknown trim_quarantine_secs scrub_gap_floor_secs zg_hold_owned_only; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
MNT="$(ct_mnt tqt)"
ct_param_set auto_defrag 0
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set zg_hold_owned_only 0
ZG_POKE="$(ct_helper zg_poke)"

# kept_then_remount <tag> <trim_quarantine_secs at the remount>: leaves the
# volume mounted, the kept run in it and the hold gone with the unmount.
kept_then_remount() {
    local img dev l0 kept
    img="$(ct_big_image 1200 "tqt$1")"
    dev="$(ct_loop "$img")"
    [ "$(cat "/sys/block/$(basename "$dev")/queue/discard_max_bytes")" != 0 ] ||
        { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_param_set trim_quarantine_secs 600
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    PROC="$(ct_procdir "$dev")"
    dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
    sync
    rm -f "$MNT/h"
    sync
    l0="$(info trim_leaked_blocks)"
    ct_param_set discard_fail_unknown 1
    fstrim -m 4M "$MNT" >/dev/null 2>&1 || true
    ct_param_set discard_fail_unknown 0
    kept=$(($(info trim_leaked_blocks) - l0))
    [ "$kept" = 2048 ] || { fail "$1: setup: the failing discard kept $kept blocks, not 2048"; ct_exit; }
    ct_umount "$MNT"
    [ "${3:-}" = unowned ] && "$ZG_POKE" "$img" 0 65535 >/dev/null # what fsck -r's rebuild leaves
    ct_param_set trim_quarantine_secs "$2"
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    PROC="$(ct_procdir "$dev")"
    DEV="$dev"
    T0=$(date +%s)
}
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
# reclaimed_within <cycles>: blocks the scrub reclaimed over that many of its cycles
reclaimed_within() {
    local r0 c0
    r0="$(info scrub_reclaimed)" c0="$(info scrub_cycles)"
    for _ in $(seq 1 120); do [ "$(info scrub_cycles)" -ge $((c0 + $1)) ] && break; sleep 0.5; done
    [ "$(info scrub_cycles)" -ge $((c0 + $1)) ] || { echo "nocycles"; return; }
    echo $(($(info scrub_reclaimed) - r0))
}

kept_then_remount ctl 1
sleep 2 # past the 1 s hold
N="$(reclaimed_within 4)"
[ "$N" != nocycles ] && [ "$N" -ge 2048 ] &&
    pass "control: with a 1 s hold the scrub reclaims the run after the remount ($N blocks)" ||
    { fail "control: the scrub reclaimed $N block(s) -- the check cannot tell"; ct_exit; }
ct_umount "$MNT"

kept_then_remount held 30
[ "$(info trim_held_zone_groups)" -ge 1 ] &&
    pass "1: setup: the re-attached Zone Group is held ($(info trim_held_zone_groups))" ||
    fail "1: setup: info reports $(info trim_held_zone_groups) held Zone Group(s)"
N="$(reclaimed_within 3)"
if [ "$N" = nocycles ]; then
    fail "1: setup: the scrub did not run three cycles"
elif [ $(($(date +%s) - T0)) -ge 30 ]; then
    fail "1: setup: the three cycles took past the 30 s hold -- the check cannot tell"
elif [ "$N" = 0 ]; then
    pass "1: three scrub cycles after the remount reclaimed nothing"
else
    fail "1: the scrub reclaimed $N block(s) inside the hold"
fi
R0="$(info scrub_reclaimed)"
for _ in $(seq 1 120); do
    [ "$(info scrub_reclaimed)" -ge $((R0 + 2048)) ] && break
    sleep 0.5
done
[ "$(info scrub_reclaimed)" -ge $((R0 + 2048)) ] && [ "$(info trim_held_zone_groups)" = 0 ] &&
    pass "2: after the hold the scrub reclaimed the run ($(($(info scrub_reclaimed) - R0)) blocks)" ||
    fail "2: after the hold: $(($(info scrub_reclaimed) - R0)) reclaimed, $(info trim_held_zone_groups) group(s) held"
ct_umount "$MNT"
N="$(CETRAFS_FSCK_DUMP_LEAKS=1 ct_fsck "$DEV" 2>&1 | grep -c '^LEAK: lba=' || true)"
[ "$N" = 0 ] && pass "2: fsck finds no leaked block" || fail "2: fsck finds $N leaked block(s)"

ct_param_set zg_hold_owned_only 1
kept_then_remount unownedctl 30 unowned
N="$(reclaimed_within 4)"
ct_param_set zg_hold_owned_only 0
[ "$N" != nocycles ] && [ "$N" -ge 2048 ] &&
    pass "3 control: claimed unowned with no hold, the scrub reclaimed the run at once ($N blocks)" ||
    fail "3 control: the scrub reclaimed $N block(s) -- the unowned claim does not reach the check"
ct_umount "$MNT"
kept_then_remount unowned 30 unowned
H="$(info trim_held_zone_groups)"
N="$(reclaimed_within 3)"
[ "$H" -ge 1 ] && [ "$N" = 0 ] && [ $(($(date +%s) - T0)) -lt 30 ] &&
    pass "3: an unowned Zone Group's claim holds it too ($H held, nothing reclaimed in three cycles)" ||
    fail "3: unowned claim: $H held, $N reclaimed, $(($(date +%s) - T0)) s in"
ct_umount "$MNT"
ct_exit
