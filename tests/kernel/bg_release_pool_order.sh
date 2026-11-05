#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a claim landing inside a Block Group's release never leaves the pool shard drifted
#
# Unowned Block Groups' capacity is counted in a pool shard on the Zone
# Group record (statfs adds it; fsck cross-checks it). A release moved
# its counters AFTER the descriptor read FREE; a claim debits the shard
# right after its own descriptor CAS. A claim landing between the two
# found no credit to debit -- refused as "below zero" -- and the credit
# then landed for a Block Group that was owned again: the shard
# overstated by a whole Block Group for good, an fsck ERR made of two
# legal moves (audit R25). The release now credits before the CAS.
#
# Staged on one node: two Block Groups, the first nearly full and the
# second empty. The heartbeat's release of the second is held after it
# reads FREE (bg_release_stall_ms) while a writer fills the first and
# has to claim the second back.
#
# CONTROL (second half): bg_release_credit_late restores the old order;
# the same moves must leave the shard drifted (fsck ERR, a refused debit).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bg_release_stall_ms ] || { skip "bg_release_stall_ms is missing"; ct_exit; }
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 1200 bgpool)"
MNT="$(ct_mnt bgpool)"
compress_timing
ct_track mnt "$MNT"
# Registered here, in the suite's own shell, so ct_exit restores them.
for k in bg_release_off bg_release_credit_late bg_release_stall_ms; do
    ct_param_set "$k" "$(cat /sys/module/cetrafs/parameters/$k)"
done
RES="$(ct_tmp bgpool-res)"

bg1() { "$MAP" "$DEV" | awk '/^bg 1 /{print}'; }
bg1_used() { bg1 | awk '{split($5,a,"[=/]"); exit !(a[2] < a[3])}'; }

# round <late>: writes "<fsck-err-lines> <refused-debits>" to $RES
round() {
    local late="$1" i=0 mark err n
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$DEV" | sed -n 's/^counts [0-9]* //p')" = 2 ] ||
        { fail "setup: the volume does not have exactly two Block Groups"; ct_exit; }
    ct_param_set bg_release_off 1
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    # Fill until a file reaches the second Block Group, then drop that
    # file: the first is nearly full, the second empty again.
    while :; do
        dd if=/dev/zero of="$MNT/f$i" bs=1M count=16 conv=fsync status=none 2>/dev/null || break
        sync
        bg1_used && break
        i=$((i + 1))
        [ "$i" -gt 60 ] && break
    done
    bg1_used || { fail "setup: the fill never reached the second Block Group"; ct_exit; }
    rm -f "$MNT/f$i"
    sync

    ct_param_set bg_release_credit_late "$late"
    ct_param_set bg_release_stall_ms 15000
    mark="$(dmesg_mark)"
    ct_param_set bg_release_off 0
    wait_for 20 'dmesg_since "'"$mark"'" | grep -q "BG 1: release stalled"' ||
        { fail "setup: the release of Block Group 1 never started"; ct_exit; }
    ct_param_set bg_release_stall_ms 0
    # The writer needs more than the first Block Group has left: it must
    # claim the second, which reads FREE right now.
    dd if=/dev/zero of="$MNT/w" bs=1M count=64 conv=fsync status=none 2>/dev/null || true
    dmesg_since "$mark" | grep -q "claimed free BG 1" ||
        { fail "setup: the writer never claimed Block Group 1 during its release"; ct_exit; }
    # Let the held release finish before looking.
    wait_for 25 'dmesg_since "'"$mark"'" | grep -q "BG 1 handed back"' || true
    ct_param_set bg_release_off 1
    ct_param_set bg_release_credit_late 0
    n="$(dmesg_since "$mark" | grep -c "claimed but its pool shard debit failed" || true)"
    ct_umount "$MNT"
    err="$(ct_fsck "$DEV" 2>&1 | grep -c '^ERR' || true)"
    ct_fsck "$DEV" 2>&1 | grep '^ERR' | head -3 >&2 || true
    echo "$err $n" >"$RES"
}

round 0
read -r ERR REF <"$RES"
log "credit before the CAS: fsck ERR lines $ERR, refused debits $REF"
[ "$REF" = 0 ] && pass "the claimant's pool debit found the release's credit" ||
    fail "the claimant's pool debit was refused $REF time(s)"
[ "$ERR" = 0 ] && pass "fsck clean: the pool shard did not drift" ||
    fail "fsck reports $ERR error(s) after a claim inside a release"

round 1
read -r ERR REF <"$RES"
log "control, credit after the CAS: fsck ERR lines $ERR, refused debits $REF"
[ "$REF" -gt 0 ] && [ "$ERR" -gt 0 ] &&
    pass "control: with the old order the debit is refused and the shard drifts" ||
    fail "control: the old order did not drift (ERR $ERR, refused $REF) -- the staging proves nothing"
ct_exit
