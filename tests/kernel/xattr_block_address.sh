#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an xattr_block pointing outside the data regions is refused, not read or written
#
# Every other address read from an inode -- extents, leaf and index
# pointers -- is checked against the data regions before the block is
# read; an inode's xattr_block was not (rule 19's asymmetry). The xattr
# writer reads that block, modifies it and writes it back, so a record
# whose xattr_block names a block in the global tables had setxattr
# write into them, provided the block carried an xattr tail.
#
# Played by copying f's real xattr block into an unused block of the
# inode table and pointing f's record at the copy. The check now sits in
# cetrafs_blk_tail_bread(), the one reader of tail-checked blocks.
#
# DISCRIMINATION: without the check the read returns the copy's value
# and the write rewrites the inode-table block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SBPOKE="$(ct_helper sb_poke)"
REC_POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 xaddr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xaddr)"
ct_mkfs_small "$DEV" >/dev/null
ITAB="$("$SBPOKE" "$DEV" | sed -n 's/^inode_table_start=//p')"
ICOUNT="$("$SBPOKE" "$DEV" | sed -n 's/^inodes_count=//p')"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

echo data >"$MNT/f"
xset() { python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", sys.argv[2].encode())' "$@"; }
xget() { python3 -I -c 'import os,sys; print(os.getxattr(sys.argv[1], "user.k").decode())' "$1"; }
xset "$MNT/f" original
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
XB="$("$REC_POKE" "$IMG" xattrblk "$INO")"
# The LAST inode slot: never handed out on a volume this empty.
FAKE=$((ITAB + ICOUNT - 1))
[ -n "$ITAB" ] && [ -n "$ICOUNT" ] && [ "$XB" -gt 0 ] ||
    { fail "setup: itab '$ITAB' count '$ICOUNT' xattr block '$XB'"; ct_exit; }
dd if="$IMG" of="$IMG" bs=4096 skip="$XB" seek="$FAKE" count=1 conv=notrunc status=none
"$REC_POKE" "$IMG" xattrblk "$INO" "$FAKE" >/dev/null
BEFORE="$(dd if="$IMG" bs=4096 skip="$FAKE" count=1 status=none | md5sum)"
pass "setup: f's xattr block copied into inode-table block $FAKE, and f points at it"

ct_mount "$DEV" "$MNT"
MARK="$(dmesg_mark)"
GOT="$(xget "$MNT/f" 2>/dev/null || true)"
[ "$GOT" != original ] && pass "getxattr does not serve the inode table as f's xattrs" ||
    fail "getxattr read f's xattrs out of the inode table"
xset "$MNT/f" CHANGED 2>/dev/null && fail "setxattr succeeded through the bad address" ||
    pass "setxattr is refused"
dmesg_since "$MARK" | grep -q "xattr block $FAKE is not a data address" &&
    pass "and the kernel names the address" || fail "no refusal logged for block $FAKE"
ct_umount "$MNT"
AFTER="$(dd if="$IMG" bs=4096 skip="$FAKE" count=1 status=none | md5sum)"
[ "$AFTER" = "$BEFORE" ] && pass "the inode-table block was not written" ||
    fail "the inode-table block was rewritten by setxattr"
ct_exit
