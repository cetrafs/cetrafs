#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record's inline index count past its 4 slots is not used as an index
#
# cetrafs_tree_last_contig_lba() picked the last inline index entry of a
# depth-2 tree as idx[eh_entries - 1], with no bound: the union has 4
# slots, and fallocate reaches it without the record check
# __cetrafs_get_block() makes. An image with eh_entries=65535 and its
# checksums restamped read ~1 MiB past the record, under inode_lock and
# invalidate_lock (rule 19).
#
# A count of 5, not 65535: the out-of-range slot then lies inside the
# record (file_seq and fd_checksum) rather than a megabyte past it, so
# the old code cannot fault the box. Two things see it: UBSAN's array
# bounds check (caught by the harness's dmesg scan), and the index-block
# read the old code aims at whatever those bytes decode to, which the
# tree reader refuses as "not a data address" -- the one that does not
# depend on how the module was built. The unused in-range slots repeat
# the first slot's interior under a range nothing maps, so the ordinary
# lookup never reads them and the hint is the only path to that message.
#
# DISCRIMINATION (measured with the bound removed): the message appears,
# and UBSAN reports array-index-out-of-bounds in file.c.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 hidx)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hidx)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# 300 extents that cannot merge (every other logical block) fill one
# leaf and push the tree to depth 2.
python3 -I - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
for i in range(300):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
EXT="$("$POKE" "$IMG" extents "$INO" 2>&1)"
grep -q "depth=2" <<<"$EXT" || { fail "setup: the file did not reach depth 2: $EXT"; ct_exit; }
pass "setup: a depth-2 file ($EXT)"

"$POKE" "$IMG" idxcount "$INO" 5 2>/dev/null
pass "setup: inline index count 5, checksums restamped"

ct_mount "$DEV" "$MNT"
MARK="$(dmesg_mark)"
# Preallocate past every mapped block: the lookup finds nothing, and the
# allocation then asks for a placement hint.
fallocate -n -o $((700 * 4096)) -l 4096 "$MNT/f" 2>/dev/null || true
OUT="$(dmesg_since "$MARK")"
if grep -q "extent index block .* is not a data address" <<<"$OUT"; then
    fail "an index read was aimed past the record's 4 inline slots: $(grep 'not a data address' <<<"$OUT" | head -1)"
else
    pass "nothing read past the record's 4 inline index slots"
fi
ct_umount "$MNT"
ct_exit
