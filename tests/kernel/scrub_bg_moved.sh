#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub frees a block only while its Block Group is still its Zone Group's
#
# The scrub re-checks, at each free, that the Zone Group it judged is
# still this node's. Block Groups are released and claimed one at a
# time, though, so the Zone Group can stay ours while the Block Group
# went back to the pool and on to a peer -- and the free then became a
# foreign free applied to whatever the new owner keeps there (audit
# 2026-11-06 L18).
#
# Staged as scrub.sh: 40 blocks leaked in BG 0, the fast scrub armed;
# scrub_bg_moved_once makes BG 0 read as released at the first free's
# ownership check. The scrub must abandon it and free nothing.
#
# B. The check runs before the free_gen bump (a CAS) and the free, outside
# the mutex: a group gone AFTER it was freed in place, or -- named foreign
# by its descriptor, as a peer's claim leaves it -- queued to that owner
# with a stamp read after the scrub's own bump, which the owner's drain
# accepts (audit 2026-11-15 BC-17). scrub_bg_moved_late moves the group
# between the checks and the free, each staging caught by one arm:
#   2. its in-core owner reads FREE: nothing freed;
#   3. routed as foreign (pf_force_foreign: a loop device has no CAW, so
#      a real peer owner cannot be staged on one node): nothing freed,
#      nothing queued;
#   4. drained, as a release does under the mutex before its swap:
#      nothing freed.
# Not staged: a descriptor a real release already wrote FREE (refused by
# the same early test as 3), and a peer's claim -- ctest's.
#
# DISCRIMINATION: checking the Zone Group alone, the scrub frees the
# leaked blocks of a Block Group that is no longer its own;
# scrub_free_owner_unchecked=1 -- 2 and 4 free, 3 queues.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in scrub_bg_moved_once scrub_bg_moved_late scrub_free_owner_unchecked; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LEAK="$(ct_helper data_leak_poke)"

DEV="$(ct_dev 560 scrubbg)"
MNT="$(ct_mnt scrubbg)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
info() { cat "$(ct_procdir "$DEV")/info"; }
reclaimed() { info | sed -n 's/^scrub_reclaimed: //p'; }
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
"$LEAK" "$DEV" 0 100 40 >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BASE="$(reclaimed)"
MARK="$(dmesg_mark)"
ct_param_set scrub_bg_moved_once 1
ct_param_set scrub 1
for _ in $(seq 1 20); do
    [ "$(cat /sys/module/cetrafs/parameters/scrub_bg_moved_once)" = N ] && break
    sleep 0.5
done
ct_param_set scrub 0
[ "$(cat /sys/module/cetrafs/parameters/scrub_bg_moved_once)" = N ] ||
    { fail "setup: the scrub never reached a free in BG 0"; ct_umount "$MNT"; ct_exit; }
sleep 1
REC="$(( $(reclaimed) - BASE ))"
[ "$REC" = 0 ] && pass "the scrub freed nothing in a Block Group that left its Zone Group" ||
    fail "the scrub freed $REC block(s) in a Block Group that is no longer its own"
dmesg_since "$MARK" | grep -q "scrub: BG 0 left ZG 0 mid-cycle" && pass "and said why" ||
    fail "no word about the Block Group moving"
umount "$MNT" # the in-core ownership was faked: nothing more on this mount

# <late 1|2> <unchecked 0|1> -> "reached= freed= queued="
late_round() {
    local dev reached=0 base q0 freed queued
    dev="$(ct_dev 560 "scrubbg$1$2")"
    ct_mkfs_small "$dev" -z 1 >/dev/null
    "$LEAK" "$dev" 0 100 40 >/dev/null
    ct_mount "$dev" "$MNT"
    base="$(sed -n 's/^scrub_reclaimed: //p' "$(ct_procdir "$dev")/info")"
    q0="$(sed -n 's/^pending_free_appends: //p' "$(ct_procdir "$dev")/info")"
    echo "$2" >/sys/module/cetrafs/parameters/scrub_free_owner_unchecked
    echo "$1" >/sys/module/cetrafs/parameters/scrub_bg_moved_late
    ct_param_set scrub 1
    for _ in $(seq 1 20); do
        [ "$(cat /sys/module/cetrafs/parameters/scrub_bg_moved_late)" = 0 ] && { reached=1; break; }
        sleep 0.5
    done
    ct_param_set scrub 0
    echo 0 >/sys/module/cetrafs/parameters/scrub_bg_moved_late
    sleep 1
    freed=$(( $(sed -n 's/^scrub_reclaimed: //p' "$(ct_procdir "$dev")/info") - base ))
    queued=$(( $(sed -n 's/^pending_free_appends: //p' "$(ct_procdir "$dev")/info") - q0 ))
    echo 0 >/sys/module/cetrafs/parameters/scrub_free_owner_unchecked
    umount "$MNT" # the ownership was faked: nothing more on this mount
    echo "reached=$reached freed=$freed queued=$queued"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }
R1="$(late_round 1 0)"
log "released late: $R1"
C1="$(late_round 1 1)"
log "control (unchecked): $C1"
R2="$(late_round 2 0)"
log "foreign late: $R2"
C2="$(late_round 2 1)"
log "control (unchecked): $C2"
R3="$(late_round 3 0)"
log "drained late: $R3"
C3="$(late_round 3 1)"
log "control (unchecked): $C3"
for v in "$R1" "$C1" "$R2" "$C2" "$R3" "$C3"; do
    [ "$(get reached "$v")" = 1 ] || { fail "setup B: the scrub never reached a free ($v)"; ct_exit; }
done
pass "setup B: the group moved between the scrub's checks and its free"
[ "$(get freed "$R1")" = 0 ] && pass "2: released after the checks, nothing was freed" ||
    fail "2: the scrub freed blocks of a group that had left ($R1)"
[ "$(get freed "$C1")" -gt 0 ] && pass "control: unchecked, the scrub freed in the group that had left" ||
    fail "control: nothing freed anyway -- the suite does not reach the free ($C1)"
[ "$(get freed "$R2")" = 0 ] && [ "$(get queued "$R2")" = 0 ] &&
    pass "3: named foreign after the checks, nothing was freed or queued" ||
    fail "3: the scrub's free went to a foreign owner ($R2)"
[ "$(get queued "$C2")" -gt 0 ] && pass "control: unchecked, the scrub's free was queued to the foreign owner" ||
    fail "control: nothing queued anyway -- the suite does not reach the foreign branch ($C2)"
[ "$(get freed "$R3")" = 0 ] && pass "4: drained after the checks, nothing was freed" ||
    fail "4: the scrub freed blocks of a group being released ($R3)"
[ "$(get freed "$C3")" -gt 0 ] && pass "control: unchecked, the scrub freed in the drained group" ||
    fail "control: nothing freed anyway -- the suite does not reach the drained check ($C3)"
ct_exit
