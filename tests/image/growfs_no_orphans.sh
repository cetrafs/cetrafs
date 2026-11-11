#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow strands nothing, and says so: orphan_blocks stays 0 through two grows
#
# A grow used to relocate the Zone Group table, the Block Group table and
# the pending-free region into a tail reserve, stranding the old copies;
# growfs counted those into the superblock's orphan_blocks and printed
# "orphaned by this grow". Grows have since stopped moving anything -- the
# reserve holds only the appended Block Group table segment, which stays
# in use -- but the count kept being added on every first grow, a false
# number persisted on disk and printed to the operator (audit 2026-11-11
# G1).
#
#  1. a first grow: orphan_blocks stays 0, nothing is reported orphaned,
#     and fsck is clean.
#  2. a second grow (its Block Groups start past the first's reserve):
#     the same.
#
# DISCRIMINATION (2026-11-11, growfs.c before this fix): 1 reads
# orphan_blocks 258 and prints "orphaned by this grow: 258 blocks", 2
# reads 260 -- four failures; fsck stays clean, which is why only this
# suite sees it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 600 gorph)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
losetup -d "$DEV"
orphans() { "$SBPOKE" "$DEV" 2>/dev/null | sed -n 's/^orphan_blocks[ =:]*\([0-9]*\).*/\1/p'; }

for n in 1 2; do
    log "$n: grow $n"
    truncate -s $((600 + n * 600))M "$IMG"
    DEV="$(ct_loop "$IMG")"
    OUT="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" || { fail "$n setup: growfs failed: $(tail -2 <<<"$OUT")"; ct_exit; }
    O="$(orphans)"
    [ -n "$O" ] || { fail "$n setup: sb_poke prints no orphan_blocks"; ct_exit; }
    [ "$O" = 0 ] && pass "$n: orphan_blocks is 0" || fail "$n: orphan_blocks reads $O after a grow that moved nothing"
    grep -qi "orphaned" <<<"$OUT" && fail "$n: growfs reports blocks orphaned: $(grep -i orphaned <<<"$OUT")" ||
        pass "$n: and growfs reports none"
    F="$(ct_fsck "$DEV" 2>&1)" && pass "$n: fsck clean" || fail "$n: fsck: $(grep -m3 ERR <<<"$F")"
    losetup -d "$DEV"
done
ct_exit
