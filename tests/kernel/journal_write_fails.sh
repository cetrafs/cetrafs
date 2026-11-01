#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a target write that FAILS must leave its journal entry live
#
# cetrafs_journal_write_block() bundles log -> write -> sync -> consume,
# and the consume is what stops a later replay re-applying a stale image
# over newer content. It ran unconditionally: the target's
# sync_dirty_buffer() result was discarded and the function returned 0,
# under a comment reading "the target is durable, so the entry is spent".
#
# That is an assertion, not a test. On a failed write the target is NOT
# durable, and consuming the entry destroyed the only copy that could
# have redone it -- while the caller was told the write succeeded. The
# journal is the last net under exactly this case, and it was being cut
# away precisely when it was needed.
#
# journal_fail_target_write makes that write report failure. It is
# deliberately NOT journal_skip_target_write, which models a CRASH:
# that one suppresses the write and returns success, because a crashed
# writer never returns. This models a live caller and a device that
# refuses, which is the case that must propagate.
#
# Discrimination: drop the check (go back to ignoring sync_dirty_buffer's
# result) and the operation below reports success, the entry is consumed,
# and the remount replays nothing -- the first and third assertions both
# fail. Verified that way before this suite was committed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(mktemp "${CT_IMG_DIR:-/tmp}/cetrafs-jfail-XXXXXX.img")"
ct_track file "$IMG"
truncate -s 560M "$IMG"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jfail)"
# A real journal: every other suite passes -J 0, which makes this path a
# no-op and the test vacuous.
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
c() { sed -n "s/^$1: //p" "$PROC"; }

# Something that journals a dirent block, with the journal known to be in
# play: without this baseline a zero below could just mean "nothing was
# ever journaled".
mkdir "$MNT/d"
W0="$(c journal_writes)"
for i in $(seq 1 20); do : > "$MNT/d/warm$i"; done
sync
[ "$(c journal_writes)" -gt "$W0" ] ||
    fail "nothing was journaled at all (journal_writes stuck at $W0) -- this volume has no journal and the suite proves nothing"
pass "the journal is in play ($(( $(c journal_writes) - W0 )) entries written)"

MARK="$(dmesg_mark)"
ct_param_set journal_fail_target_write 1

# 1. The caller must be told. The operation is allowed to fail in any
# way it likes -- what it may not do is report success.
# Three, not forty: each failure logs, and a flooded kernel log scrolls
# the dmesg mark out from under the assertion below.
RC=0
for i in 1 2 3; do : > "$MNT/d/doomed$i" 2>/dev/null || RC=$?; done
sync 2>/dev/null || true
[ "$RC" != 0 ] &&
    pass "a failed target write reaches the caller (errno $RC)" ||
    fail "every operation reported SUCCESS while its target write was failing -- the error is being swallowed"

dmesg_since "$MARK" | grep -q "stays LIVE for replay" &&
    pass "and it says the entry was kept rather than consumed" ||
    fail "no 'stays LIVE' message: $(dmesg_since "$MARK" | grep -i journal | tail -2)"

ct_param_set journal_fail_target_write 0

# 2. The area must still be dirty on disk, which is what brings replay
# back to it. The journal refuses to park a flag CLEAN while slots are
# busy, and a kept entry keeps its slot busy.
ct_umount "$MNT"
dmesg_since "$MARK" | grep -q "leaving flag dirty" &&
    pass "the area was left DIRTY at unmount, so a replay will come back to it" ||
    log "note: the flag was parked clean at unmount -- the replay assertion below is the one that counts"

# 3. The entry is still good: a remount replays it.
ct_mount "$DEV" "$MNT"
sleep 1
APPLIED="$(c journal_replay_applied)"
[ "$APPLIED" -gt 0 ] &&
    pass "the remount's replay applied $APPLIED kept entr$([ "$APPLIED" = 1 ] && echo y || echo ies) -- the write was repairable" ||
    fail "replay applied nothing: the entry did not survive the failed write, so nothing could have repaired it"

ct_umount "$MNT"

# 4. What the replay leaves behind, stated rather than hidden.
#
# A refused write leaves an entry live, and replay redoes it -- but the
# operation that wrote it is NOT crashed here, it returned an error and
# unwound, freeing the inode it had allocated. The journal covers dirent,
# xattr and extent-leaf blocks, not the global inode bitmap, so redoing
# the dirent block can name an inode that no longer exists.
#
# fsck reports that and `-r` deliberately leaves it: removing a name is
# not a repair with one derivable answer (see fsck.c's header). So the
# assertion is not "clean", it is "consistent and diagnosable" -- the
# residue is a dangling entry and NOTHING from the class fsck refuses to
# reason about. That is the right trade against the bug this suite
# guards: consuming the entry lost the write silently, with nothing left
# to report or repair.
OUT="$(ct_fsck "$DEV" 2>&1 || true)"

echo "$OUT" | grep -q "dangling entry" &&
    pass "the replay's residue is a dangling entry -- reported, and left by design" ||
    log "note: no dangling entry this run (the unwound create's dirent was not among the replayed blocks)"

! echo "$OUT" | grep -qiE "overlap|checksum|outside|leaked [1-9]" &&
    pass "and nothing from the class fsck refuses to reason about: no overlap, no bad checksum, no stray extent" ||
    fail "the replay left damage beyond a dangling name: $(echo "$OUT" | grep -iE "overlap|checksum|outside|leaked" | head -2)"

ct_exit
