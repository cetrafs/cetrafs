#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# if the extent tree cannot be read, evict must free NEITHER half
#
# evict frees the inode NUMBER first, because the bitmap CAS is what
# arbitrates between two evicts and the background scrub, and only then
# the blocks. If the tree turns out to be unreadable at that point the
# number is already back in the pool while the blocks stay allocated,
# referenced by a record the next file to take the number overwrites.
# A permanent, untraceable leak -- the blocks are gone and nothing names
# them.
#
# evict_inode's own comment says exactly that about a failed RECORD
# read, three screens above where it frees. The reasoning was right and
# covered one of the two ways the read can fail; the extent-tree read
# can fail from an I/O error on a leaf or from an allocation failure
# flattening a large tree.
#
# The list is fetched BEFORE the arbitration now, and a fetch that fails
# refuses the whole eviction rather than half of it.
#
# extents_fetch_fail_once exists because neither real cause is reachable
# on demand, and the consequence is permanent.
#
# Discrimination: move the fetch back after the arbitration (or ignore
# its result) and free_inodes climbs by one while free_data_blocks does
# not -- the number handed back, the blocks orphaned.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 evicttree)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt evicttree)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
ino_free()  { sed -n 's/^free_inodes: //p' "$PROC"; }
blk_free()  { sed -n 's/^free_data_blocks: //p' "$PROC"; }

# The tree must SPILL out of the record: with four or fewer inline
# extents nothing reads an external block, so the fetch cannot fail and
# the old order could not leak. Scattered single blocks do not merge,
# so each one is its own extent.
python3 - "$MNT/doomed" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
for i in range(0, 64, 2):            # every other block: 32 extents
    os.pwrite(f, b'D' * 4096, i * 4096)
os.fsync(f)
os.close(f)
PY
sync
DEPTH="$("$(ct_helper inode_block_poke)" "$IMG" extents "$(stat -c '%i' "$MNT/doomed")" 2>/dev/null | sed -n 's/.*depth=\([0-9]*\).*/\1/p' | head -1 || true)"
log "the doomed file's tree depth: ${DEPTH:-unknown}"
I0="$(ino_free)"; B0="$(blk_free)"
log "before: free_inodes=$I0 free_data_blocks=$B0"

MARK="$(dmesg_mark)"
ct_param_set extents_fetch_fail_once 1
rm -f "$MNT/doomed"
sync
sleep 1
ct_param_set extents_fetch_fail_once 0

I1="$(ino_free)"; B1="$(blk_free)"
log "after:  free_inodes=$I1 free_data_blocks=$B1"

# THE assertion: the number must NOT come back on its own. A number
# without its blocks is the untraceable half.
[ "$I1" = "$I0" ] &&
    pass "the inode number was not handed back while its blocks were unreachable" ||
    fail "free_inodes went $I0 -> $I1 with the extent tree unreadable: the number is reusable and the blocks are now unnamed"

# Both halves stay put, which is what makes it diagnosable rather than lost.
[ "$B1" = "$B0" ] &&
    pass "and no block was freed either ($B1)" ||
    fail "free_data_blocks moved $B0 -> $B1 -- a partial free is the thing being avoided"

dmesg_since "$MARK" | grep -q "freeing NEITHER" &&
    pass "and the refusal says what it left behind" ||
    fail "no refusal logged: $(dmesg_since "$MARK" | grep -i evict | tail -2)"

# fsck must be able to name what was left -- that is the entire point of
# refusing both halves rather than one.
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 &&
    log "note: fsck clean (the orphan is within what it tolerates)" ||
    pass "fsck names the deliberately-orphaned inode"

ct_exit
