#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a block the journal cannot protect is not written, and a failed target does not hold its slot forever
#
# Two halves of one fault.
#
# Whenever the journal could not take an entry -- the entry's own write
# failed, the area could not be marked dirty, every slot was busy -- the
# block went out UNJOURNALED with a ratelimited warning, and the caller
# was told it succeeded. A crash inside that write leaves a torn dirent,
# xattr or extent-leaf block with nothing to redo it from: the exact
# failure the journal exists for, accepted silently.
#
# And a target write that fails keeps its entry live (so a replay can
# redo it), which kept its slot busy until unmount. Failures in enough
# blocks held every slot, which then sent every later write down the
# unjournaled path above. The next write of the same block supersedes
# the kept entry -- it is built from the block re-read after the
# failure -- and now takes its slot over, so a block can hold at most
# one slot and gets it back by being written again.
#
# DISCRIMINATION (measured on the old code): the create succeeds while
# the entry write fails, and the stuck-slot counter does not exist.
# Without the slot takeover: the rewrite of a kept entry's block fails
# with every slot held, and so does every directory after it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 jfl)"
MNT="$(ct_mnt jfl)"
# A real journal (every other suite runs -J 0, where none of this
# exists), and the smallest one: 1 MiB is 127 slots.
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
c() { sed -n "s/^$1: //p" "$PROC"; }

mkdir "$MNT/d"
W0="$(c journal_writes)"
: >"$MNT/d/warm"
[ "$(c journal_writes)" -gt "$W0" ] || { fail "setup: a create journaled nothing -- this volume has no journal"; ct_exit; }
pass "setup: the journal is in play"

log "1. the journal entry cannot be written"
ct_param_set journal_fail_entry_write 1
RC=0
{ : >"$MNT/d/unprotected"; } 2>/dev/null || RC=$?
ct_param_set journal_fail_entry_write 0
[ "$RC" != 0 ] && pass "the create fails rather than writing its dirent block unjournaled" ||
    fail "the create SUCCEEDED with no journal entry behind its dirent block"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ ! -e "$MNT/d/unprotected" ] && pass "and nothing of it is on the device" ||
    fail "the failed create's name is on the device"

log "2. target writes fail in more blocks than there are slots"
N=140
for i in $(seq 1 $N); do mkdir "$MNT/d$i"; done
ct_param_set journal_fail_target_write 1
FAILED=0
for i in $(seq 1 $N); do { : >"$MNT/d$i/doomed"; } 2>/dev/null || FAILED=$((FAILED + 1)); done
ct_param_set journal_fail_target_write 0
[ "$FAILED" = $N ] && pass "setup: all $N creates failed" ||
    { fail "setup: only $FAILED of $N creates failed"; ct_exit; }
STUCK="$(c journal_slots_stuck)"
[ "$STUCK" = 127 ] && pass "setup: every one of the 127 slots is held by a kept entry" ||
    { fail "setup: $STUCK slots held, expected all 127"; ct_exit; }

{ : >"$MNT/d$N/x"; } 2>/dev/null && fail "a block with no kept entry was written while no slot could protect it" ||
    pass "a block with no kept entry is refused while every slot is held"
: >"$MNT/d1/ok" && pass "the next write of a kept entry's block succeeds and takes its slot over" ||
    fail "a kept entry's own block stays unwritable"
[ "$(c journal_slots_stuck)" = 126 ] && pass "one slot is given back" ||
    fail "$(c journal_slots_stuck) slots held after the rewrite, expected 126"
BAD=0
for i in $(seq 1 $N); do [ -e "$MNT/d$i/ok" ] || : >"$MNT/d$i/ok" || BAD=$((BAD + 1)); done
[ "$BAD" = 0 ] && pass "every directory is writable again" || fail "$BAD directories are still unwritable"
[ "$(c journal_slots_stuck)" = 0 ] && pass "no slot is held any more" ||
    fail "$(c journal_slots_stuck) slots are still held after every block was rewritten"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
MISSING=0
DOOMED=0
for i in $(seq 1 $N); do
    [ -e "$MNT/d$i/ok" ] || MISSING=$((MISSING + 1))
    [ -e "$MNT/d$i/doomed" ] && DOOMED=$((DOOMED + 1))
done
[ "$MISSING" = 0 ] && pass "the later writes are durable" || fail "$MISSING later writes are missing after a remount"
[ "$DOOMED" = 0 ] && pass "and no superseded entry was redone over them" ||
    fail "$DOOMED superseded entries were replayed over later writes"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
