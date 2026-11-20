#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r says what a partial run did about orphans, and links none of them
#
# A directory block the walk could not read means the names in it were not
# counted, so tally_partial defers every decision that depends on a name:
# an unnamed inode is left as it is, and nothing is linked into
# /lost+found. The per-inode WARN said so, but the rebuild of the unread
# block then printed that its files "reached /lost+found by inode number"
# -- in the same run that had linked none of them (audit 2026-11-15 M-47).
# The summary now states the count that was left alone and the reason,
# and the rebuild line says the link is deferred to the next run.
#
# Planted, as fsck_repair_unread_names.sh does: inode 3 is allocated with
# nlink 1 and its only name is in a directory block the walk skips (an
# impossible name length makes the whole block fail its check). Then:
#   1. the run must not claim any file reached /lost+found;
#   2. the summary must say how many unnamed inodes it left alone, and why;
#   3. the victim's inode must still be allocated afterwards;
#   4. the next run, which reads every block, links the victim.
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_OLD_PARTIAL_MSG=1 restores the pre-fix
# rebuild wording, and then the run claims a file reached /lost+found. The
# control must show that claim; the fixed run must not.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
DPOKE="$(ct_helper dirtree_poke)"
SBPOKE="$(ct_helper sb_poke)"
BMP="$(ct_helper bmap_poke)"
VICTIM=3
# A block in Block Group 0's data region for the planted directory (the
# same placement fsck_repair_unread_names.sh uses; see its comment).
data_blk() { # <dev>
    local d
    d="$("$(ct_helper bg_poke)" "$1" 0 --dump)"
    echo $(( $(tr ' ' '\n' <<<"$d" | sed -n 's/^start_block=\([0-9]*\).*/\1/p' | awk 'NR == 1') + \
             $(tr ' ' '\n' <<<"$d" | sed -n 's/^off_data_region=\([0-9]*\).*/\1/p' | awk 'NR == 1') + 1100 ))
}

# <tag> <old 0|1> -> RES, OUT
round() {
    local img dev ibm
    img="$(ct_image 560 "partial$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$ROOT/userspace/fsck.cetra" "$dev" >/dev/null 2>&1 ||
        { fail "control: the fresh image is already reported corrupt"; ct_exit; }
    "$OPOKE" "$img" "$VICTIM" 1 0 >/dev/null || { fail "setup: orphan_poke could not plant the victim"; ct_exit; }
    "$DPOKE" "$img" 2 "$(data_blk "$dev")" "$VICTIM" >/dev/null ||
        { fail "setup: dirtree_poke could not plant the directory"; ct_exit; }
    blockdev --flushbufs "$dev"
    ibm="$("$SBPOKE" "$dev" | sed -n 's/^inode_bmap_start=//p')"
    [ -n "$ibm" ] || { fail "setup: sb_poke prints no inode_bmap_start"; ct_exit; }
    [ "$("$BMP" "$dev" "$ibm" "$((VICTIM - 1))")" = 1 ] ||
        { fail "setup: the victim's inode bit is not set"; ct_exit; }
    if [ "$2" = 1 ]; then
        OUT="$(CETRAFS_TEST_FSCK_OLD_PARTIAL_MSG=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    else
        OUT="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    fi
    blockdev --flushbufs "$dev"
    IBM=$ibm
    DEV=$dev
}

round f 0
grep -q "could not be read" <<<"$OUT" ||
    { fail "setup: the walk did not skip the directory block ($(grep -E '^ERR|^WARN' <<<"$OUT" | head -2 | tr '\n' ' '))"; ct_exit; }
pass "setup: the walk reported a directory block it could not read"

if grep -q "reached /lost+found" <<<"$OUT"; then
    fail "fsck -r claims a file reached /lost+found in a run that linked none"
else
    pass "1: the run does not claim any file reached /lost+found"
fi
grep -Eq "^  left [0-9]+ unnamed inode\(s\) alone: a directory block could not be read" <<<"$OUT" &&
    pass "2: the summary counts the unnamed inodes it left alone, and says why" ||
    fail "2: no summary of the deferred orphans: $(grep -E 'left|linked' <<<"$OUT" | head -3 | tr '\n' ' ')"
grep -q "inode $VICTIM left as it is" <<<"$OUT" ||
    fail "2: the victim was not reported as left as it is"
if grep -q "linked .* into /lost+found" <<<"$OUT"; then
    fail "fsck -r reports a link into /lost+found in a run that could not read every directory block"
else
    pass "the run links nothing into /lost+found"
fi
[ "$("$BMP" "$DEV" "$IBM" "$((VICTIM - 1))")" = 1 ] &&
    pass "3: the victim's inode is still allocated after fsck -r" ||
    fail "fsck -r freed inode $VICTIM, which a directory block it could not read still names"

# The deferred link lands in the run that reads every block.
OUT2="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
grep -q "linked [0-9]* orphaned inode(s) into /lost+found" <<<"$OUT2" &&
    pass "4: the next run, which reads every block, links the deferred inode" ||
    fail "4: the next run linked nothing: $(grep -E '^ERR|^WARN|linked' <<<"$OUT2" | head -3 | tr '\n' ' ')"

# Negative control: the pre-fix wording claims the link this run did not make.
round c 1
grep -q "reached /lost+found" <<<"$OUT" &&
    pass "control: with the pre-fix wording the run claims a file reached /lost+found (the claim check fails on it)" ||
    fail "control: the pre-fix wording did not reach the claim -- the suite does not measure it"
ct_exit
