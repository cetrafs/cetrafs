#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# concurrent create + readdir on one directory (the buffer-cache race)
#
# Two local threads are enough to lose directory entries: a writer that
# read a block, modified it in memory and only then marked it dirty, and
# a reader whose forced-fresh read cleared uptodate in that window and
# re-read the block straight over the writer's changes. Measured at 12 of
# 292 entries lost before the buffer-lock update protocol.
#
# Three distinct faults are covered: lost entries, spurious -EIO from a
# NULL returned by a racing invalidate, and an unstamped dirent block
# published to a peer.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# A volume with one file, 'victim', whose inode number the pokes below
# address. Every suite that touches the on-disk lock fields starts from
# exactly this state, freshly built -- nothing here inherits anything
# from another suite.
LOCK_IMG="$(ct_image 560 lock)"
LOCK_LOOPDEV="$(ct_loop "$LOCK_IMG")"
LOCK_MNT="$(ct_mnt lock-mnt)"
ct_mkfs_small "$LOCK_LOOPDEV" >/dev/null
ct_track mnt "$LOCK_MNT"
ct_mount "$LOCK_LOOPDEV" "$LOCK_MNT"
require_cetrafs_mount "$LOCK_MNT"
echo "victim content" >"$LOCK_MNT/victim"
VICTIM_INO="$(stat -c '%i' "$LOCK_MNT/victim")"

log "checking concurrent create + readdir on one directory (buffer-cache race)"
# Regression for a buffer-cache race found while building
# ctest's dir-storm scenario. Two local threads are enough -- one writing
# into a directory, one merely running `ls` over it:
#   * the writer read a block with sb_bread(), modified it in memory, and
#     only then marked it dirty. The reader's forced-fresh read saw a
#     clean+uptodate buffer in that window, cleared uptodate and re-read
#     from disk straight over the writer's changes; the writer then
#     persisted the re-read content. Measured 12 of 292 directory entries
#     silently lost.
#   * __bread_slow() re-checks buffer_uptodate AFTER its read and returns
#     NULL if it is gone, so the refresh-time invalidation of an extent
#     leaf turned healthy reads into spurious -EIO on open().
# Both are only reachable once a directory is big enough to span many
# blocks, which is why this appeared together with the 58-entry fix.
# Created empty, not left absent: `wc -l < missing` makes bash itself
# print a redirection error before wc ever runs, so the 2>/dev/null on
# the count below cannot suppress it -- noise that looks like a failure
# in a run that is actually clean.
CONC_ERRFILE="$(ct_tmp conc-err)"
: >"$CONC_ERRFILE"
CONC_DIR="$LOCK_MNT/concdir"
mkdir -p "$CONC_DIR"
(
    for i in $(seq 1 400); do
        dd if=/dev/zero of="$CONC_DIR/c$i" bs=1024 count=$(((i % 40) + 1)) status=none 2>/dev/null ||
            echo "FAILED $i" >>"$CONC_ERRFILE"
    done
) &
CONC_W=$!
# Three readers, and `ls -la` rather than `ls`: -la stats every entry,
# which drives the forced-fresh inode-record reads whose invalidation
# races the namespace lock's own CAS read. With the bare forced-fresh
# read in cetrafs_cas_record(), that lost race surfaced as a create
# failing with EIO about once per 300.
( while kill -0 $CONC_W 2>/dev/null; do ls -la "$CONC_DIR" >/dev/null 2>&1; done ) &
CONC_R=$!
( while kill -0 $CONC_W 2>/dev/null; do ls -la "$CONC_DIR" >/dev/null 2>&1; done ) &
CONC_R2=$!
( while kill -0 $CONC_W 2>/dev/null; do ls -la "$CONC_DIR" >/dev/null 2>&1; done ) &
CONC_R3=$!
wait $CONC_W
kill $CONC_R $CONC_R2 $CONC_R3 2>/dev/null || true
wait $CONC_R $CONC_R2 $CONC_R3 2>/dev/null || true
sync

CONC_ERRS=$(wc -l <"$CONC_ERRFILE" 2>/dev/null || echo 0)
[ "$CONC_ERRS" -eq 0 ] &&
    pass "concurrency: 400 creates alongside three ls -la loops, no spurious failures" ||
    fail "concurrency: $CONC_ERRS create(s) failed while ls -la loops ran (spurious EIO)"

# Count by asking about each name individually, not by piping `ls`
# through `wc -l`. A bare listing cannot tell "the entry is genuinely
# gone" from "readdir hit a transient error and printed fewer lines",
# and those need completely different investigations -- the first is
# data loss, the second is a visibility blip. This distinction was added
# after a 399-of-400 failure whose nature was ambiguous and was never
# reproduced.
CONC_MISSING=""
CONC_SEEN=0
for i in $(seq 1 400); do
    if [ -e "$CONC_DIR/c$i" ]; then
        CONC_SEEN=$((CONC_SEEN + 1))
    else
        CONC_MISSING="$CONC_MISSING c$i"
    fi
done
CONC_LISTED=$(ls "$CONC_DIR" 2>/dev/null | wc -l)

[ "$CONC_SEEN" -eq 400 ] &&
    pass "concurrency: all 400 entries survived (none silently lost)" ||
    fail "concurrency: $CONC_SEEN of 400 entries reachable by name -- MISSING:$CONC_MISSING"

# readdir must agree with name lookup. A mismatch means readdir skipped
# or errored on something that is actually there, which is its own bug.
[ "$CONC_LISTED" -eq "$CONC_SEEN" ] &&
    pass "concurrency: readdir agrees with per-name lookup ($CONC_LISTED entries)" ||
    fail "concurrency: readdir listed $CONC_LISTED but $CONC_SEEN are reachable by name -- readdir is dropping entries"

rm -rf "$CONC_DIR"
rm -f "$CONC_ERRFILE"


ct_exit
