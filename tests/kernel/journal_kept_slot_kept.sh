#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a kept journal entry's slot stays held when a rewrite of its block gives up
#
# An entry whose target write failed is kept live for replay, its slot
# held. The next write of the same block takes that slot over -- its own
# entry supersedes the kept one -- and it used to release the hold
# BEFORE its last two checks (the DIRTY-flag write, the fence). Refused
# there, it returned with the kept entry still live on the device but
# its slot free, and the next entry of any block took the slot and wrote
# over the one entry replay needed (leafdefer review 2026-11-08, item 4). Now a take
# that gives up holds the slot again.
#
#   setup: a directory entry whose target write fails
#     (journal_fail_target_write): the entry is kept, one slot stuck.
#   the act: a second entry in the same directory block, refused at the
#     take's fence check (journal_take_fenced_once).
#   the check: the slot is still held (journal_slots_stuck unchanged),
#     and the remount's replay finds the kept entry.
#
# DISCRIMINATION: with the hold released on that exit, journal_slots_stuck
# drops by one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_take_fenced_once journal_fail_target_write; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

IMG="$(ct_image 560 jkept)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jkept)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
PROC="$(ct_procdir "$DEV")/info"
c() { sed -n "s/^$1: //p" "$PROC"; }

mkdir "$MNT/d"
: >"$MNT/d/warm"
sync
S0="$(c journal_slots_stuck)"
ct_param_set journal_fail_target_write 1
: >"$MNT/d/live" 2>/dev/null || true
ct_param_set journal_fail_target_write 0
S1="$(c journal_slots_stuck)"
[ "$S1" -gt "$S0" ] && pass "setup: a failed target write kept its entry ($S0 -> $S1 slot(s) held)" ||
    { fail "setup: no slot held after the failed target write ($S0 -> $S1)"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set journal_take_fenced_once 1
: >"$MNT/d/again" 2>/dev/null && R=0 || R=$?
ct_param_set journal_take_fenced_once 0
[ "$R" != 0 ] && pass "setup: the rewrite of the same block was refused at the take" ||
    fail "setup: the rewrite went through (the knob never fired)"
S2="$(c journal_slots_stuck)"
[ "$S2" = "$S1" ] && pass "the kept entry's slot is still held ($S2)" ||
    fail "the kept entry's slot was released by the refused take ($S1 -> $S2): the next entry overwrites it"

ct_umount "$MNT"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$MARK" | grep -qE "journal replay: node 0 replayed [1-9]" &&
    pass "the remount's replay found the kept entry" ||
    fail "the remount replayed nothing: $(dmesg_since "$MARK" | grep -i 'journal replay' | tail -2)"
ct_umount "$MNT"
ct_exit
