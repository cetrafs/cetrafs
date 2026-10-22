#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck rebuilds a directory block whose dirent tail is unreadable
#
# Found in the field: a dirent block that read as all zeros. The kernel
# refuses the whole directory (-EIO on readdir), and because rmdir cannot
# confirm an unreadable directory is empty, the directory could not be
# deleted either. fsck reported the fault and stopped, so the only
# remaining answer was to reformat a volume that was otherwise fine.
#
# The repair is derivable, which is why it belongs in -r: the entries are
# already gone (that is what "no magic" means), any inode they named is
# found unreachable and linked into /lost+found, and the two structural
# entries are known -- '.' is the directory and '..' is whoever names it.
#
# Both directions are asserted, the way every control in this directory
# is: the fault is DETECTED on an image that was clean a moment earlier,
# and the repair actually clears it rather than merely reporting less.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 direntrep)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "control: the freshly-made image is clean" ||
    fail "control: the fresh image is already reported corrupt -- nothing below would mean anything"

# Root's own dirent block, located through the record rather than
# hardcoded: mkfs is free to move the data region.
#
# Root is deliberately the subject here. It is the only directory a
# freshly-made image HAS, and it is also the worst case: its check runs
# before any content pass and used to `return 1` outright, so an
# unreadable root dirent block made the whole volume unrepairable as
# well as unusable. The generic directory path is the same repair,
# exercised against a real volume on the test cluster.
PHYS="$("$IPOKE" "$IMG" extents 1 | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
[ -n "$PHYS" ] && [ "$PHYS" != "0" ] &&
    pass "root's dirent block is at $PHYS" ||
    fail "could not locate root's dirent block (got '$PHYS')"

dd if=/dev/zero of="$DEV" bs=4096 seek="$PHYS" count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV"

OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
echo "$OUT" | grep -qE "has no dirent-tail magic|root dirent block tail checksum invalid" &&
    pass "detected: fsck reports the unreadable dirent block" ||
    fail "fsck did not report the zeroed dirent block: $(echo "$OUT" | grep -E '^ERR' | head -2 | tr '\n' ' ')"

# The repair itself.
REP="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
echo "$REP" | grep -qE "rebuilt unreadable dirent block|rebuilt the root directory's dirent block" &&
    pass "repaired: fsck -r rebuilt the block" ||
    fail "fsck -r did not rebuild it: $(echo "$REP" | grep -E '^ERR|rebuilt' | head -3 | tr '\n' ' ')"

blockdev --flushbufs "$DEV"
FINAL="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" && FRC=0 || FRC=$?
[ "$FRC" = "0" ] &&
    pass "the volume is clean again after the repair" ||
    fail "still not clean (rc=$FRC): $(echo "$FINAL" | grep -E '^ERR' | head -3 | tr '\n' ' ')"

# A rebuilt block that lacked '.' or '..' would leave the directory
# structurally broken in a way the kernel notices but fsck's own
# namespace pass would also have objected to -- so a clean run above
# already proves both entries are there. Asserted explicitly anyway:
# "fsck says clean" is the claim most worth double-checking, since it is
# the one a repair is tempted to reach by reporting less.
echo "$FINAL" | grep -q "namespace: every directory is reachable from the root" &&
    pass "the rebuilt block carries a usable '.' and '..'" ||
    fail "the namespace pass did not confirm reachability: $FINAL"

ct_exit
