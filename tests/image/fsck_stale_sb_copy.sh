#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not restore block 0 from a copy that may predate a grow
#
# growfs writes block 0's copy (block 2048) only after block 0 itself. A
# growfs killed between the two leaves the copy at the old layout beside
# a block 0 at the new one. If block 0 is then lost, fsck checked the
# volume through the copy and, under -r, wrote that older superblock to
# block 0 -- dropping the grown space from under every file written
# into it since (audit 2026-11-22 N-61). Through the old copy the grow
# shows as a table segment linked past the end the copy publishes or,
# for a first grow (linked from the superblock itself), as the next
# Block Group's header where growfs puts it -- both also what a grow
# that never published leaves; with block 0 gone fsck cannot tell the
# two apart, so it now restores nothing. This case is a first grow.
#
# Offline grows of a 700 MiB volume to 1400 MiB, then block 0 zeroed:
#   control: the copy carried along (a normal grow). fsck -r restores
#            block 0, at the grown size.
#   stale:   CETRAFS_GROWFS_TEST_NO_SB_COPY=1, the copy left at 700 MiB.
#            Setup: the copy is smaller than block 0 was. fsck -r must
#            say the copy may predate a grow and leave block 0 alone --
#            never write the 700 MiB superblock.
#
# DISCRIMINATION (measured on the unfixed code): the stale case restores
# block 0 at 700 MiB.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
IMG="$(ct_image 1600 fssc)"
DEV="$(ct_loop "$IMG")"
GROWFS="$ROOT/userspace/growfs.cetra"
REP=2048
total_of() { # <lba>: total_blocks of the superblock image at that block, or "none"
    local t
    t="$(ct_tmp fssc-sb)"
    dd if="$DEV" of="$t" bs=4096 skip="$1" count=1 status=none
    "$SBPOKE" "$t" 2>/dev/null | sed -n 's/^total_blocks=//p' | head -1 || true
}
zero0() { dd if=/dev/zero of="$DEV" bs=4096 count=1 conv=notrunc,fsync status=none; blockdev --flushbufs "$DEV"; }

# grown <stale 0|1> -> "<block 0 total before> <copy total> <block 0 total after fsck -r> <fsck said stale yes|no>"
grown() {
    local before copy after said=no out
    ct_mkfs "$DEV" -s 700M -f >/dev/null
    if [ "$1" = 1 ]; then
        CETRAFS_GROWFS_TEST_NO_SB_COPY=1 "$GROWFS" "$DEV" -s 1400M >/dev/null 2>&1 || true
    else
        "$GROWFS" "$DEV" -s 1400M >/dev/null 2>&1 || true
    fi
    blockdev --flushbufs "$DEV"
    before="$(total_of 0)"
    copy="$(total_of $REP)"
    zero0
    out="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
    blockdev --flushbufs "$DEV"
    grep -q "its copy may predate a grow" <<<"$out" && said=yes
    after="$(total_of 0)"
    echo "${before:-none} ${copy:-none} ${after:-none} $said"
}

read -r B C A S <<<"$(grown 0)"
[ "$B" != none ] && [ "$B" = "$C" ] && [ "$A" = "$B" ] &&
    pass "control: with the copy current, fsck -r restores block 0 at the grown size ($A blocks)" ||
    { fail "control: block 0 $B, copy $C, after fsck -r $A -- nothing to compare against"; ct_exit; }

read -r B C A S <<<"$(grown 1)"
[ "$B" != none ] && [ "$C" != none ] && [ "$C" -lt "$B" ] &&
    pass "setup: the copy ($C blocks) predates the grow block 0 had ($B blocks)" ||
    { fail "setup: block 0 $B, copy $C -- the stale copy was not arranged"; ct_exit; }
[ "$S" = yes ] && [ "$A" != "$C" ] &&
    pass "fsck -r says the copy may predate a grow and does not write it to block 0 (block 0: $A)" ||
    fail "fsck -r restored block 0 from the stale copy ($A blocks; said stale: $S)"
ct_exit
