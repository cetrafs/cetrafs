#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not leak an inode and a block per run on a spilled root
#
# fsck finds and builds /lost+found only in a depth-0 root. A root grown
# past its 4 inline extents (an external leaf) skipped the lookup, then
# allocated a fresh lost+found -- inode and block -- that it could not
# link, and left both allocated. Every -r run with an orphan to place
# leaked one more of each. It now refuses before allocating.
#
# DISCRIMINATION (measured on the old fsck): the allocated-inode count
# grows ("could not add /lost+found to the root directory").
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ORPHAN="$(ct_helper orphan_poke)"
REC="$(ct_helper inode_block_poke)"
SB_POKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 lfroot)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lfroot)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# Grow the root a block at a time with a data allocation between each
# growth, so its blocks cannot merge: five extents, depth 1.
for b in $(seq 0 6); do
    for i in $(seq 1 15); do : >"$MNT/r${b}_$i"; done
    dd if=/dev/zero of="$MNT/pad$b" bs=4096 count=1 status=none
    sync
done
ct_umount "$MNT"
grep -q "depth=1" <<<"$("$REC" "$IMG" extents 1 2>&1)" ||
    { fail "setup: the root did not spill: $("$REC" "$IMG" extents 1 2>&1)"; ct_exit; }
pass "setup: the root directory has an external leaf"

"$ORPHAN" "$IMG" 1000 1 0 >/dev/null
pass "setup: inode 1000 is an orphan that still claims a link"

# Allocated inodes, counted off the inode bitmap itself.
used() {
    local d start blocks
    blockdev --flushbufs "$DEV"
    d="$("$SB_POKE" "$IMG")"
    start="$(grep -oP '^inode_bmap_start=\K[0-9]+' <<<"$d")"
    blocks="$(grep -oP '^inode_bmap_blocks=\K[0-9]+' <<<"$d")"
    python3 -I -c 'import sys
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2]) * 4096)
print(sum(bin(b).count("1") for b in f.read(int(sys.argv[3]) * 4096)))' "$IMG" "$start" "$blocks"
}
FSCK="${FSCK_BIN:-$ROOT/userspace/fsck.cetra}"
U0="$(used)"
[ -n "$U0" ] && [ "$U0" -gt 0 ] || { fail "setup: could not count allocated inodes"; ct_exit; }
OUT="$("$FSCK" -r "$DEV" 2>&1 || true)"
grep -q "inode 1000 is allocated (nlink=1) but NO directory entry names it" <<<"$OUT" &&
    pass "setup: fsck sees the orphan and has to place it" ||
    { fail "setup: fsck did not report the orphan: $(grep -E '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')"; ct_exit; }
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
U3="$(used)"
[ "$U0" = "$U3" ] && pass "three fsck -r runs allocated nothing ($U0 inodes in use)" ||
    fail "fsck -r allocated an unlinkable lost+found: $U0 -> $U3 inodes in use"
ct_exit
