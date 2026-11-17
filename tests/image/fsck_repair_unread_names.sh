#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not free an unnamed inode while a directory block was unread
#
# An inode with nlink 0 and no name is what a delete leaves when it could
# not free the number, and fsck -r frees it. Its only name, though, may sit
# in a directory block this run could not read -- then "no name" is a
# reading failure, not a fact. The walk counts a skipped block's names as
# nothing, and the orphan pass judged on that count: fsck -r freed the
# inode, its number went back to the allocator, and the name that was
# still on the volume named a number that was now free for reuse (audit
# 2026-11-14 U5). The count repairs already had a guard for this
# (tally_partial); the free branches did not.
#
# The suite plants that: a victim inode with nlink 0 whose only name is
# in a directory block the walk skips (an impossible name length makes
# the whole block fail its check), and runs fsck -r. The victim's bit in
# the inode bitmap must still be set afterwards, and the run must say why
# it did not free it.
#
# DISCRIMINATION (measured on the unfixed code): the orphan pass clears the
# victim's bit; the bitmap byte reads 11 (bit 2 clear).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
DPOKE="$(ct_helper dirtree_poke)"
SBPOKE="$(ct_helper sb_poke)"
# A block in Block Group 0's data region for the planted directory: it
# was the literal 2700, inside the data region until block 0's copy
# moved every table up by 2048 blocks (A-7); there it fell in metadata,
# fsck disabled repair for that instead, and the suite tested nothing.
data_blk() { # <dev>
    local d
    d="$("$(ct_helper bg_poke)" "$1" 0 --dump)"
    echo $(( $(tr ' ' '\n' <<<"$d" | sed -n 's/^start_block=\([0-9]*\).*/\1/p' | awk 'NR == 1') + \
             $(tr ' ' '\n' <<<"$d" | sed -n 's/^off_data_region=\([0-9]*\).*/\1/p' | awk 'NR == 1') + 1100 ))
}

IMG="$(ct_image 560 fsckunread)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 ||
    { fail "control: the fresh image is already reported corrupt"; ct_exit; }

VICTIM=3
"$OPOKE" "$IMG" "$VICTIM" 0 0 >/dev/null || { fail "setup: orphan_poke could not plant the victim"; ct_exit; }
"$DPOKE" "$IMG" 2 "$(data_blk "$DEV")" "$VICTIM" >/dev/null || { fail "setup: dirtree_poke could not plant the directory"; ct_exit; }
blockdev --flushbufs "$DEV"

IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
[ -n "$IBM" ] || { fail "setup: sb_poke prints no inode_bmap_start"; ct_exit; }
bit_of() { # the victim's bit in the inode bitmap, as the device has it
    local bit=$((VICTIM - 1)) byte
    byte="$(dd if="$DEV" bs=1 skip=$((IBM * 4096 + bit / 8)) count=1 status=none | od -An -tu1 | tr -d ' ')"
    echo $(((byte >> (bit % 8)) & 1))
}
[ "$(bit_of)" = 1 ] || { fail "setup: the victim's inode bit is not set"; ct_exit; }

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
log "fsck -r: $(grep -c . <<<"$OUT") lines"

if grep -q "partial\|could not be read" <<<"$OUT"; then
    pass "setup: the walk reported a directory block it could not read"
else
    fail "setup: the walk did not skip the directory block ($(grep -E '^ERR|^WARN' <<<"$OUT" | head -2 | tr '\n' ' '))"
fi
[ "$(bit_of)" = 1 ] && pass "the victim's inode is still allocated after fsck -r: its only name was unread" ||
    fail "fsck -r freed inode $VICTIM, which a directory block it could not read still names"
grep -q "inode $VICTIM left as it is" <<<"$OUT" && pass "and fsck -r says why it did not decide" ||
    fail "fsck -r gave no reason for leaving inode $VICTIM alone"
ct_exit
