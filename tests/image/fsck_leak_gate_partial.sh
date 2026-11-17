#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not clear leaked blocks while a directory block was unread
#
# The orphan pass refuses to free an inode while a directory block could
# not be read: the name that says whether the inode is garbage may be in
# it (fsck_repair_unread_names.sh). Clearing leaked blocks is the same
# kind of act -- not undoable, decided from a walk that did not see
# everything -- and it ran anyway (audit 2026-11-15 BM-66). It now waits
# for a run that reads every block, and says so.
#
# Planted: a directory block the walk skips (fsck_repair_unread_names.sh's
# impossible name length) and one leaked data block (a bitmap bit nothing
# references):
#   1. after fsck -r the leaked block's bit is still set;
#   2. the run says why it did not clear it.
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_LEAK_UNGATED=1 (as before): the bit
# is cleared.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
DPOKE="$(ct_helper dirtree_poke)"
BGPOKE="$(ct_helper bg_poke)"
LEAKBIT=8000
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
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <ungated 0|1> -> RES
round() {
    local img dev d0 bm off byte out
    img="$(ct_image 560 "flg$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$OPOKE" "$img" 3 0 0 >/dev/null || { fail "setup: orphan_poke failed"; ct_exit; }
    "$DPOKE" "$img" 2 "$(data_blk "$dev")" 3 >/dev/null || { fail "setup: dirtree_poke failed"; ct_exit; }
    d0="$("$BGPOKE" "$dev" 0 --dump)"
    bm=$(( $(tr ' ' '\n' <<<"$d0" | sed -n 's/^start_block=\([0-9]*\).*/\1/p' | awk 'NR == 1') + $(tr ' ' '\n' <<<"$d0" | sed -n 's/^off_data_bmap=\([0-9]*\).*/\1/p' | awk 'NR == 1') ))
    off=$((bm * 4096 + LEAKBIT / 8))
    printf '\x01' | dd of="$img" bs=1 seek="$off" conv=notrunc status=none
    blockdev --flushbufs "$dev"
    if [ "$2" = 1 ]; then
        out="$(CETRAFS_TEST_FSCK_LEAK_UNGATED=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    else
        out="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    fi
    blockdev --flushbufs "$dev"
    byte="$(dd if="$dev" bs=1 skip="$off" count=1 status=none | od -An -tu1 | tr -d ' ')"
    RES="partial=$(grep -c 'could not be read' <<<"$out" || true) leaked=$(grep -c 'leaked' <<<"$out" || true)"
    RES="$RES bit=$((byte & 1)) said=$(grep -c 'not cleared: some directory blocks could not be read' <<<"$out" || true)"
}

round c 1
C="$RES"
log "control (ungated): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get partial "$R")" -ge 1 ] && [ "$(get leaked "$R")" -ge 1 ] ||
    { fail "setup: the run saw no unread block or no leak ($R)"; ct_exit; }
[ "$(get bit "$R")" = 1 ] && pass "1: the leaked block's bit is still set" || fail "1: $R"
[ "$(get said "$R")" -ge 1 ] && pass "2: the run said why it did not clear it" || fail "2: $R"
[ "$(get bit "$C")" = 0 ] && pass "control: ungated, the leak was cleared over a partial walk" ||
    fail "control: the bit survived without the gate -- the suite does not reach the clear: $C"
ct_exit
