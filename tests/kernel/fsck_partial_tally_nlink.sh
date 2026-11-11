#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not lower a link count while names it could not read are missing from the count
#
# fsck counts every directory entry that names a file and repairs nlink
# to that count. A dirent block it cannot read (no tail, an incoherent
# table) is skipped, its names uncounted -- so the count is a LOWER
# bound wherever a block was skipped, and a file named once in a good
# block and once in the skipped one read refs=1 against nlink=2 and was
# lowered to 1. Should that block outlive the run, the file is one unlink
# away from being freed while still named; fsck had no business deciding
# it from a partial count (audit 2026-11-11 F3). Now, while any block was
# skipped, counts are only raised -- one left too high leaks the file,
# never frees a named one -- and the next run, with the rebuilt blocks
# counted, settles it.
#
# The rebuild of the bad block happens in the same run, so the end state
# of ONE run was consistent either way here; what is asserted is the
# rule: the first run does not lower a count it could not complete.
#
#  1. a file with two names, the second in a later dirent block of the
#     same directory, that block zeroed: fsck -r leaves nlink at 2 and
#     says to run again.
#  2. the second fsck -r sets it to 1; a third run is clean.
#
# DISCRIMINATION (2026-11-11, the tally_partial gate removed): 1 finds
# nlink lowered to 1 by the first run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
FSCK="$ROOT/userspace/fsck.cetra"

IMG="$(ct_image 560 ptally)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ptally)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
echo x >"$MNT/d/aa_x"
for i in $(seq 1 400); do : >"$MNT/d/f$i"; done
ln "$MNT/d/aa_x" "$MNT/d/zz_second"
DINO="$(stat -c %i "$MNT/d")"
[ "$(stat -c %h "$MNT/d/aa_x")" = 2 ] || { fail "setup: the file does not have two names"; ct_exit; }
ct_umount "$MNT"

# The dirent block holding the second name, and the one holding the first.
blocks() { "$IPOKE" "$IMG" extents "$DINO" | sed -n 's/^ext [0-9]* .*phys=\([0-9]*\).*len=\([0-9]*\).*/\1 \2/p'; }
holding() {
    local p l k
    while read -r p l; do
        for k in $(seq 0 $((l - 1))); do
            dd if="$IMG" bs=4096 skip=$((p + k)) count=1 status=none | grep -aq "$1" && { echo $((p + k)); return; }
        done
    done <<<"$(blocks)"
}
B1="$(holding aa_x)"
B2="$(holding zz_second)"
[ -n "$B1" ] && [ -n "$B2" ] && [ "$B1" != "$B2" ] ||
    { fail "setup: the two names are not in two different blocks ($B1, $B2): $(blocks | tr '\n' ' ')"; ct_exit; }
dd if=/dev/zero of="$DEV" bs=4096 seek="$B2" count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV"

# nlink: the first name's link count, as a mount reads it.
nlink() {
    local n
    blockdev --flushbufs "$DEV"
    ct_mount "$DEV" "$MNT"
    n="$(stat -c %h "$MNT/d/aa_x" 2>/dev/null || echo gone)"
    ct_umount "$MNT"
    echo "$n"
}

# ------------------------------------------------------------------- 1
log "1: the first repair, one block of names unread"
OUT="$("$FSCK" -r "$DEV" 2>&1 || true)"
grep -q "has no dirent-tail magic" <<<"$OUT" || { fail "setup: fsck did not skip the zeroed block: $(grep -m2 ERR <<<"$OUT")"; ct_exit; }
N1="$(nlink)"
[ "$N1" = 2 ] && pass "1: nlink left at 2 -- not lowered to a count that missed a block" ||
    fail "1: nlink is $N1 after a run whose count skipped the block naming the file"
grep -q "link counts are only raised in this run -- run fsck again" <<<"$OUT" &&
    pass "1: and it said to run again" || fail "1: no word that the counts are partial"

# ------------------------------------------------------------------- 2
log "2: the second repair counts every block"
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
N2="$(nlink)"
[ "$N2" = 1 ] && pass "2: the second run set nlink to 1 (one name left)" || fail "2: nlink is $N2 after the second run"
OUT="$("$FSCK" "$DEV" 2>&1)" && pass "2: and the volume is clean" || fail "2: still not clean: $(grep -m3 ERR <<<"$OUT")"
ct_exit
