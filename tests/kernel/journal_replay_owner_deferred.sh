#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an entry whose owner is unreadable waits for the next replay pass
#
# Replay confirms each entry's target is still its owner's before the
# redo, and the owner walk of a leaf entry crosses the file's interior
# block -- very likely another entry of the same batch, torn by the
# crash, and redone only later in the same replay. An owner still
# unreadable after the retries aborted the whole area: the node could
# never mount again and no peer could reclaim it (audit 2026-11-14
# A-10). It now waits for the next pass, like an owner the entry cannot
# reach yet, and is refused only once a pass redoes nothing
# (journal_replay_owner_unreadable.sh keeps that half).
#
# Staged single-node as journal_replay_owner_unreadable.sh: two
# directories' dirent blocks, each with an entry carrying its older
# state guarded against the newer, planted in this node's own area with
# txn ids 1 (the root's) and 2 (d's). TEST ONLY journal_owner_read_fail=5
# makes exactly the first entry's five owner reads fail.
#   setup: the five failures were spent;
#   1. the mount succeeds;
#   2. both entries were redone (both directories back to the older state);
#   3. dmesg says the first was deferred.
#
# DISCRIMINATION: the pre-fix module aborts on the first entry: 1 and 2 fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_owner_read_fail ] || { skip "journal_owner_read_fail is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_image 560 jowdef)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jowdef)"
BLK_R="$(ct_tmp jowdef-r)"
BLK_D="$(ct_tmp jowdef-d)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_param_set journal_owner_read_fail 0

ls_of() { ls "$1" | sort | tr '\n' ' '; }
target() { dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1; }

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/d"
echo data >"$MNT/f"
echo data >"$MNT/d/f"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
T_R="$(target "$MARK")"
MARK="$(dmesg_mark)"
touch "$MNT/d/alpha"
T_D="$(target "$MARK")"
ct_umount "$MNT"
[ -n "$T_R" ] && [ -n "$T_D" ] && [ "$T_R" != "$T_D" ] ||
    { fail "setup: the creates did not journal two dirent blocks ('$T_R' '$T_D')"; ct_exit; }
dd if="$IMG" of="$BLK_R" bs=4096 skip="$T_R" count=1 status=none # state A
dd if="$IMG" of="$BLK_D" bs=4096 skip="$T_D" count=1 status=none
mount -t cetrafs "$DEV" "$MNT"
WANT_R="$(ls_of "$MNT")"
WANT_D="$(ls_of "$MNT/d")"
touch "$MNT/beta" "$MNT/d/beta" # state B
ct_umount "$MNT"

JOURNAL_POKE_TXN=1 "$JPOKE" "$IMG" "$NID" 0 "$T_R" "$BLK_R" --guard-current >/dev/null
JOURNAL_POKE_TXN=2 "$JPOKE" "$IMG" "$NID" 1 "$T_D" "$BLK_D" --guard-current >/dev/null
ct_param_set journal_owner_read_fail 5
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    GOT_R="$(ls_of "$MNT")"
    GOT_D="$(ls_of "$MNT/d")"
    ct_umount "$MNT"
    M=mounted
else
    M=refused
fi
LEFT="$(cat /sys/module/cetrafs/parameters/journal_owner_read_fail)"
ct_param_set journal_owner_read_fail 0
[ "$LEFT" = 0 ] || { fail "setup: the owner reads were not reached ($LEFT of 5 failures left)"; ct_exit; }
pass "setup: the first entry's owner reads failed five times"
[ "$M" = mounted ] && pass "1: the mount succeeded" || fail "1: the mount was refused -- one unreadable owner aborted the area"
[ "$M" = mounted ] && [ "$GOT_R" = "$WANT_R" ] && [ "$GOT_D" = "$WANT_D" ] &&
    pass "2: both entries were redone" || fail "2: root '${GOT_R:-}' (want '$WANT_R'), d '${GOT_D:-}' (want '$WANT_D')"
dmesg_since "$MARK" | grep -q "unreadable -- deferred to the next pass" && pass "3: the first entry was deferred" ||
    fail "3: no deferral in dmesg"
ct_exit
