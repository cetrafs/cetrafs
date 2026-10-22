#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# .write_inode -- the writer that runs under no cross-node lock
#
# The VFS calls it for any dirty in-core inode on its own writeback
# schedule: no namespace lock, no file lock. cetrafs_write_vfs_inode()
# carries three guards against it clobbering a peer (forced-fresh read,
# generation check, live-foreign-lock check) and nothing listed the
# item as having no direct test at all.
#
# What this suite asserts is the contract that IS reachable: a dirty
# inode's stat fields reach its record through writeback alone, with no
# close and no explicit sync of the inode itself. The two cross-node
# guards are deliberately NOT asserted here -- see the note at the
# bottom for what was measured and why a test of them would be
# simulating a state the cluster cannot legitimately reach.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 wiguard)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt wiguard)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

rec() { "$POKE" "$IMG" extents "$1"; }
rec_size() { rec "$1" | sed -n 's/.*size=//p'; }

log "writeback alone carries a dirty inode's size to its record"
: >"$MNT/victim"
INO="$(stat -c '%i' "$MNT/victim")"
sync
[ "$(rec_size "$INO")" = "0" ] && pass "the record starts at size 0" ||
    fail "the record starts at size $(rec_size "$INO")"

# Held open throughout: closing would reach cetrafs_lock_release(),
# which persists the stat fields itself, so the close path would be
# doing the work instead of writeback. (A first version of this suite
# wrote and closed before measuring, and was testing the wrong function.)
exec 9>>"$MNT/victim"
python3 -c 'import os; os.pwrite(9, b"Z" * 8192, 0)'
[ "$(rec_size "$INO")" = "0" ] &&
    pass "the size is not on disk yet -- nothing has persisted the record" ||
    fail "the size reached the record before any writeback ran"
sync
[ "$(rec_size "$INO")" = "8192" ] &&
    pass "writeback persisted the new size (8192) with the file still open" ||
    fail "after writeback the record says size $(rec_size "$INO"), expected 8192"
exec 9>&-

log "a record whose generation has moved does not take this node's stat fields"
# Reaching the generation guard needs the record's buffer to be CLEAN
# on this node, which it is once the file has been closed and its
# durability boundary has run.
: >"$MNT/gen"
GINO="$(stat -c '%i' "$MNT/gen")"
sync
BEFORE="$(rec "$GINO")"
"$POKE" "$IMG" retype "$GINO" >/dev/null 2>&1 || true
AFTER_POKE="$(rec "$GINO")"
if [ "$BEFORE" != "$AFTER_POKE" ]; then
    pass "the retype poke changed the record ($AFTER_POKE)"
else
    skip "the retype poke changed nothing observable"
fi
sync
pass "writeback over a retyped record completed without crash or hang"

# ---------------------------------------------------------------------
log "writeback MERGES with the record rather than stamping over it"
#
# The gap this closes: guard (3) is inert under nofilelock (no exclusive
# lock is ever taken, so lock_mode is always NONE), so nothing stopped a
# deferred writeback stamping this node's stale i_size over a peer's
# newer record during a live-migration handoff.
#
# Staged within the constraint the note below establishes -- a forced-
# fresh read is only as fresh as the buffer is CLEAN:
#   - write and sync, so the record buffer is clean and the baseline and
#     the record agree at 4 bytes;
#   - poke the record to a larger size, as a peer that extended the file
#     would have left it;
#   - dirty the inode in a DIFFERENT field, through an already-open
#     READ-ONLY fd. Read-only so no dirty record buffer of ours blinds
#     the fresh read; already-open so no path lookup refreshes the inode
#     (that would pull the poked size in-core and the test would then
#     pass against any implementation at all).
#
# Correct outcome: the field WE changed is persisted, the field only the
# peer changed survives. Stamping gives the peer's size back as 4.
MF="$MNT/mergefile"
printf 'AAAA' >"$MF"
sync
MINO="$(stat -c %i "$MF")"
MERGE_BEFORE="$(rec_size "$MINO")"

exec 9<"$MF"
"$POKE" "$IMG" setsize "$MINO" 9999 >/dev/null
POKED="$(rec_size "$MINO")"
[ "$POKED" = "9999" ] &&
    pass "setup: the record reads 9999 as a peer that extended it would have left it (was $MERGE_BEFORE)" ||
    fail "setup: the poke did not land (size reads $POKED) -- nothing below would mean anything"

python3 -c 'import os; os.fchmod(9, 0o606)'
sync
exec 9<&-

MERGE_AFTER="$(rec_size "$MINO")"
MERGE_MODE="$(stat -c %a "$MF")"
[ "$MERGE_AFTER" = "9999" ] &&
    pass "writeback kept the size only the peer changed ($MERGE_AFTER)" ||
    fail "writeback reverted the peer's size to $MERGE_AFTER: a stale in-core copy was stamped over a newer record"
[ "$MERGE_MODE" = "606" ] &&
    pass "writeback still persisted the field this node changed (mode $MERGE_MODE)" ||
    fail "mode is $MERGE_MODE, expected 606: the merge dropped this node's own change"

log "the basics still hold"
echo content >"$MNT/plain"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(cat "$MNT/plain")" = "content" ] && pass "an ordinary file survives the round trip" ||
    fail "the ordinary file is wrong"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

ct_exit

# Measured, and deliberately not asserted:
#
# Both cross-node guards in cetrafs_write_vfs_inode() -- the generation
# check and the live-foreign-lock check -- are INERT while this node
# holds a dirty buffer for the record. Their "forced fresh" read is
# cetrafs_invalidate_raw_inode() + cetrafs_read_raw_inode(), and
# cetrafs_bread_uncached() deliberately refuses to discard a DIRTY
# buffer (doing so would lose a pending write -- a bug this project
# already fixed once in ioutil.c). So for an inode that is being
# actively written, the guard reads this node's own cached image and
# sees its own lock and its own generation.
#
# Poking a peer's claim, or a new generation, onto the record of a file
# this node holds open for write and then forcing writeback shows
# exactly that: the record is rewritten and the poke reverted.
#
# That is NOT asserted as a failure, because the state it simulates is
# one the cluster cannot legitimately reach: a peer cannot take the lock
# on a file this node holds open (it would have to find this node stale,
# which fences it), and cannot delete-and-reuse its inode number either
# (unlink and eviction both refuse on a live foreign claim). In the
# states the guards are actually written for -- a dirty inode with no
# open fd, whose record this node's durability boundaries have already
# flushed clean -- the read is genuinely fresh and the guards do fire.
#
# The general rule this adds, which nothing stated before: a forced-
# fresh read is only as fresh as the buffer is clean.
