#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed entry write never destroys the kept entry whose slot it took over
#
# An entry whose target write failed is kept live for replay, its slot
# held, and the next write of the same block takes that slot over. When
# that next write could not even build its entry -- no buffer for the
# payload or the header -- the single-block path zeroed the slot's header,
# which still held the kept entry: the one redo of a target the device
# had refused, gone, and the slot handed to the next entry (audit
# 2026-11-22, N-67). The batch path already held such a slot again
# (cetrafs_journal_untake_batch()); the single-block path now does too.
#
#   setup: a directory entry whose target write fails
#     (journal_fail_target_write): the entry is kept, one slot held.
#   the act: a second entry in the same directory block, whose payload
#     buffer cannot be had (journal_entry_getblk_fail, one-shot).
#   the check: the slot is still held, journal_reused_kept counts it,
#     and the remount's replay finds the kept entry.
#
# And when the superseding entry was refused part-way -- its header
# refused, its payload written over the kept entry's: the kept header
# then fails its payload check at replay, so the entry is gone whatever
# the slot does. Holding the slot and saying "the kept entry stays" was
# false (the N-67 residual). Now:
#   L. header refused (meta_write_nospc_block on the slot's header),
#      payload landed: the loss is said, the mount stops, and nothing
#      claims the entry stays.
#
# DISCRIMINATION: the control, in-suite -- journal_reused_zeroed=1, the
# old exit: the slot is released and the remount replays nothing. For L,
# journal_reused_payload_ignored=1 holds the slot as before: it says the
# kept entry stays, and the remount replays nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_entry_getblk_fail journal_reused_zeroed journal_fail_target_write journal_reused_payload_ignored \
    meta_write_nospc_block; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
MNT="$(ct_mnt jreuse)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set journal_reused_zeroed 0
ct_param_set journal_entry_getblk_fail 0
ct_param_set journal_fail_target_write 0
ct_param_set journal_reused_payload_ignored 0
ct_param_set meta_write_nospc_block 0
ct_param_set space_wait_secs 300
SBPOKE="$(ct_helper sb_poke)"

# round <tag> <zeroed> -> RES
round() {
    local dev proc s0 s1 s2 k0 k1 r mark rep
    dev="$(ct_dev 560 "jreuse$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")/info"
    c() { sed -n "s/^$1: //p" "$proc"; }
    mkdir "$MNT/d"
    : >"$MNT/d/warm"
    sync
    s0="$(c journal_slots_stuck)"
    ct_param_set journal_fail_target_write 1
    : >"$MNT/d/live" 2>/dev/null || true
    ct_param_set journal_fail_target_write 0
    s1="$(c journal_slots_stuck)"
    [ "$s1" -gt "$s0" ] || { fail "$1 setup: no slot held after the failed target write ($s0 -> $s1)"; ct_exit; }
    k0="$(c journal_reused_kept)"
    echo "$2" >/sys/module/cetrafs/parameters/journal_reused_zeroed
    ct_param_set journal_entry_getblk_fail 1
    : >"$MNT/d/again" 2>/dev/null && r=0 || r=$?
    echo 0 >/sys/module/cetrafs/parameters/journal_reused_zeroed
    [ "$(cat /sys/module/cetrafs/parameters/journal_entry_getblk_fail)" = N ] && [ "$r" != 0 ] ||
        { fail "$1 setup: the rewrite of the block was not refused at its entry (rc $r)"; ct_exit; }
    ct_param_set journal_entry_getblk_fail 0
    s2="$(c journal_slots_stuck)"
    k1="$(c journal_reused_kept)"
    ct_umount "$MNT"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    rep="$(dmesg_since "$mark" | grep -cE 'journal replay: node 0 replayed [1-9]' || true)"
    ct_umount "$MNT"
    RES="held_before=$s1 held_after=$s2 reused_kept=$((k1 - k0)) replayed=$rep"
    log "$1: $RES"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2; }

# round_l <tag> <payload_ignored> -> RES
round_l() {
    local dev proc mark slot node js jb hdr rep
    dev="$(ct_dev 560 "jreusel$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")/info"
    mkdir "$MNT/d"
    : >"$MNT/d/warm"
    sync
    mark="$(dmesg_mark)"
    ct_param_set journal_fail_target_write 1
    : >"$MNT/d/live" 2>/dev/null || true
    ct_param_set journal_fail_target_write 0
    slot="$(dmesg_since "$mark" | grep -oP 'journal: txn [0-9]+ slot \K[0-9]+' | tail -1)"
    node="$(sed -n 's/^this_node_id: //p' "$proc")"
    js="$("$SBPOKE" "$dev" | sed -n 's/^node_journal_start=//p')"
    jb="$("$SBPOKE" "$dev" | sed -n 's/^node_journal_blocks=//p')"
    [ -n "$slot" ] && [ -n "$node" ] && [ -n "$js" ] && [ -n "$jb" ] ||
        { fail "$1 setup: slot '$slot' node '$node' journal '$js'/'$jb'"; ct_exit; }
    hdr=$((js + node * jb + 1 + slot * 2))
    echo "$2" >/sys/module/cetrafs/parameters/journal_reused_payload_ignored
    # The header stays refused for the header's retire too, an overwrite
    # that waits for space: short, so it ends in the stop it ends in anyway.
    echo 2 >/sys/module/cetrafs/parameters/space_wait_secs
    echo "$hdr" >/sys/module/cetrafs/parameters/meta_write_nospc_block
    mark="$(dmesg_mark)"
    : >"$MNT/d/again" 2>/dev/null || true
    echo 0 >/sys/module/cetrafs/parameters/meta_write_nospc_block
    echo 0 >/sys/module/cetrafs/parameters/journal_reused_payload_ignored
    RES="lost=$(dmesg_since "$mark" | grep -c 'is lost -- the entry that was to supersede it' || true)"
    RES="$RES stays=$(dmesg_since "$mark" | grep -c 'the kept entry it was to supersede stays' || true)"
    RES="$RES stopped=$(sed -n 's/^stopped: //p' "$proc" | tr ' ' _)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    rep="$(dmesg_since "$mark" | grep -cE 'journal replay: node [0-9]+ replayed [1-9]' || true)"
    ct_umount "$MNT"
    RES="$RES replayed=$rep"
    log "L $1: $RES"
}

round ctl 1
[ "$(get held_after "$RES")" -lt "$(get held_before "$RES")" ] && [ "$(get replayed "$RES")" = 0 ] &&
    pass "control: zeroed, the kept entry's slot was released and the remount replayed nothing ($RES)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $RES"
round fixed 0
[ "$(get held_after "$RES")" = "$(get held_before "$RES")" ] && [ "$(get reused_kept "$RES")" = 1 ] &&
    pass "the kept entry's slot is still held after the failed entry ($RES)" ||
    fail "the failed entry gave up the kept entry's slot: $RES"
[ "$(get replayed "$RES")" -ge 1 ] && pass "the remount's replay found the kept entry" ||
    fail "the remount replayed nothing: $RES"
round_l ctl 1
[ "$(get stays "$RES")" -ge 1 ] && [ "$(get replayed "$RES")" = 0 ] &&
    pass "L control: held as before, it said the kept entry stays -- and the remount replayed nothing ($RES)" ||
    fail "L control: the hazard did not reproduce -- the check cannot tell: $RES"
round_l fixed 0
[ "$(get lost "$RES")" -ge 1 ] && [ "$(get stays "$RES")" = 0 ] && [ "$(get stopped "$RES")" != none ] &&
    pass "L: the superseding entry refused part-way: the kept entry's loss is said and the mount stopped ($RES)" ||
    fail "L: $RES"
ct_exit
