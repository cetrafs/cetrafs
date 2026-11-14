#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r repoints a recovered directory's '..' only in a block it has shown sound
#
# A directory recovered into /lost+found gets its '..' repointed, and
# the block is restamped -- which makes it checksum-valid whatever it
# held. fsck_set_dotdot() did that without the soundness test the link
# path has (U6), and did it AFTER linking, so a directory it then could
# not repoint was named by lost+found while its '..' still named the old
# parent (re-audit of the 2026-11-14 fixes).
#
# A /lost+found is made the normal way, its first entry ('.') given a
# file type no writer produces (checksum restamped: only the coherence
# test sees it), and its name removed from the root, so the next fsck -r
# finds it an orphan directory to recover into a new /lost+found.
#   1. its first block is left byte-for-byte as it was;
#   2. fsck -r says why it was not recovered.
#
# DISCRIMINATION (measured on the unfixed code): the block is rewritten
# with '..' naming the new /lost+found and restamped.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
IPOKE="$(ct_helper inode_block_poke)"
FPOKE="$(ct_helper dirent_field_poke)"

IMG="$(ct_image 560 ddsound)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
SCR="$(ct_tmp ddsound-blk)"

"$OPOKE" "$IMG" 3 1 0 >/dev/null && "$IPOKE" "$IMG" setsize 3 4096 >/dev/null ||
    { fail "setup: could not plant the orphan"; ct_exit; }
blockdev --flushbufs "$DEV"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
LF="$(sed -n 's/.*created \/lost+found (inode \([0-9]*\)).*/\1/p' <<<"$OUT" | head -1)"
[ -n "$LF" ] || { fail "setup: fsck -r did not create /lost+found: $(tail -2 <<<"$OUT")"; ct_exit; }
blockdev --flushbufs "$DEV"
PHYS="$("$IPOKE" "$IMG" extents "$LF" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
RPHYS="$("$IPOKE" "$IMG" extents 1 | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
[ -n "$PHYS" ] && [ -n "$RPHYS" ] || { fail "setup: no block for /lost+found ($LF) or the root"; ct_exit; }
# The root's entry naming lost+found: 266-byte slots.
SLOT="$(python3 -c '
import sys, struct
b = open(sys.argv[1], "rb"); b.seek(int(sys.argv[2]) * 4096); blk = b.read(4096)
for k in range(4096 // 266):
    if struct.unpack_from("<Q", blk, k * 266)[0] == int(sys.argv[3]):
        print(k); break' "$DEV" "$RPHYS" "$LF")"
[ -n "$SLOT" ] || { fail "setup: the root names no inode $LF"; ct_exit; }

"$FPOKE" "$IMG" "$PHYS" 0 file_type 9 >/dev/null
"$FPOKE" "$IMG" "$RPHYS" "$SLOT" inode 0 >/dev/null
blockdev --flushbufs "$DEV"
before="$(dd if="$DEV" bs=4096 skip="$PHYS" count=1 status=none | md5sum)"

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
grep -q "inode $LF" <<<"$OUT" || { fail "setup: fsck -r never considered inode $LF: $(grep -E 'WARN|ERR' <<<"$OUT" | head -3)"; ct_exit; }
after="$(dd if="$DEV" bs=4096 skip="$PHYS" count=1 status=none | md5sum)"
[ "$before" = "$after" ] && pass "1: the unsound first block of the recovered directory was not rewritten" ||
    fail "1: fsck -r restamped a block it had not shown sound"
grep -q "no sound first block with '..'" <<<"$OUT" && pass "2: fsck -r says why it was not recovered" ||
    fail "2: no reason given: $(grep -E "inode $LF" <<<"$OUT" | head -2)"
ct_exit
