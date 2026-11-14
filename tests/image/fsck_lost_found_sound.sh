#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r writes an orphan's name only into a dirent block it has shown sound
#
# An unnamed inode with a size is linked into /lost+found by fsck -r. The
# link finds a free slot in the directory's blocks and re-stamps the block
# -- and a re-stamp makes the block checksum-valid whatever it held. A
# block with an entry no writer would have written (a file type past
# CETRAFS_FT_SOCK) passes the walk, which does not look at file types, so
# it is read as sound and then written into: the tail is re-stamped and
# the damage is certified as intact (audit 2026-11-14 U6).
#
# The suite makes /lost+found the normal way (fsck -r links one orphan
# into it: the positive control), then gives its first entry a file type
# no writer produces, and orphans a second inode. The second orphan must
# not be written into that block. The block is checked as bytes on the
# device, not by the tool's own account of it.
#
# DISCRIMINATION (measured on the unfixed code): the second orphan's name
# lands in the block, and the run says "linked".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
IPOKE="$(ct_helper inode_block_poke)"
FPOKE="$(ct_helper dirent_field_poke)"

IMG="$(ct_image 560 lfsound)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
SCR="$(ct_tmp lfsound-blk)"

"$OPOKE" "$IMG" 3 1 0 >/dev/null && "$IPOKE" "$IMG" setsize 3 4096 >/dev/null ||
    { fail "setup: could not plant the first orphan"; ct_exit; }
blockdev --flushbufs "$DEV"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
LF="$(sed -n 's/.*created \/lost+found (inode \([0-9]*\)).*/\1/p' <<<"$OUT" | head -1)"
[ -n "$LF" ] || { fail "control: fsck -r did not create /lost+found: $(tail -2 <<<"$OUT")"; ct_exit; }
blockdev --flushbufs "$DEV"
PHYS="$("$IPOKE" "$IMG" extents "$LF" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
[ -n "$PHYS" ] && [ "$PHYS" != 0 ] || { fail "setup: no block for /lost+found inode $LF"; ct_exit; }
dd if="$DEV" of="$SCR" bs=4096 skip="$PHYS" count=1 status=none
grep -aq '#3' "$SCR" && pass "control: the first orphan was linked into a sound /lost+found block" ||
    fail "control: the first orphan's name is not in /lost+found"

# Its first entry (the '.') now has a file type no writer produces; the
# block is otherwise intact and its tail is re-stamped, so every checksum
# and structure test still passes.
"$FPOKE" "$IMG" "$PHYS" 0 file_type 9 >/dev/null
"$OPOKE" "$IMG" 5 1 0 >/dev/null && "$IPOKE" "$IMG" setsize 5 4096 >/dev/null ||
    { fail "setup: could not plant the second orphan"; ct_exit; }
blockdev --flushbufs "$DEV"

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
if grep -q "could not be read" <<<"$OUT"; then
    fail "setup: the walk skipped a directory block, so the link path was not what was measured"
else
    pass "setup: the walk read the damaged block as sound, so the link path runs"
fi
dd if="$DEV" of="$SCR" bs=4096 skip="$PHYS" count=1 status=none
if grep -aq '#5' "$SCR"; then
    fail "fsck -r wrote a name into a /lost+found block it had not shown sound"
else
    pass "the second orphan's name was not written into the unsound block"
fi
grep -q "is not sound, so no name was written" <<<"$OUT" &&
    pass "and fsck -r says why" || fail "fsck -r gave no reason for leaving the block alone"
ct_exit
