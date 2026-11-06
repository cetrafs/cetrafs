#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck gives back the block it took when lost+found has no extent slot to grow into
#
# Linking an orphan into a lost+found whose blocks are all full takes a
# new data block first and only then looks for an extent slot. With all
# four inline slots used and the block not contiguous with the last, the
# link fails -- and the block stayed allocated and referenced by nothing
# (audit 2026-11-06 L26).
#
# Staged: /lost+found filled to exactly four full, non-contiguous blocks
# (a one-block spacer file written after every entry), and one orphan
# whose dirent is erased. fsck -r cannot link it; the fsck after must
# report no leaked block.
#
# DISCRIMINATION: without the give-back, one block reads as leaked.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"
PER=15 # CETRAFS_DIRENTS_PER_BLOCK

DEV="$(ct_dev 560 lffull)"
MNT="$(ct_mnt lffull)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
mkdir "$MNT/lost+found" "$MNT/sp"
dd if=/dev/urandom of="$MNT/wanted" bs=4096 count=1 status=none
for i in $(seq 1 $((4 * PER - 2))); do # '.' and '..' take two slots
    : >"$MNT/lost+found/e$i"
    dd if=/dev/zero of="$MNT/sp/s$i" bs=4096 count=1 status=none
    sync -f "$MNT"
done
LF="$(stat -c %i "$MNT/lost+found")"
ROOT_INO="$(stat -c %i "$MNT")"
ct_umount "$MNT"
EXT="$("$IPOKE" "$DEV" extents "$LF" 2>&1)"
grep -q "depth=0 entries=4 " <<<"$EXT" || { fail "setup: lost+found is not four inline extents: $EXT"; ct_exit; }
"$CPOKE" "$DEV" dirent "$ROOT_INO" wanted >/dev/null
blockdev --flushbufs "$DEV"
OUT0="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "leaked" <<<"$OUT0" && { fail "setup: leaks before the repair: $(grep leaked <<<"$OUT0")"; ct_exit; }
pass "setup: lost+found holds four full extents ($EXT)"

R="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "could not be linked into /lost+found (no room in it)" <<<"$R" || { fail "setup: the repair did not fail to link into a full lost+found: $(grep -E '^(ERR|WARN)' <<<"$R" | head -3)"; ct_exit; }
"$IPOKE" "$DEV" extents "$LF" 2>&1 | grep -q "depth=0 entries=4 " ||
    { fail "setup: lost+found grew after all ($("$IPOKE" "$DEV" extents "$LF" 2>&1))"; ct_exit; }
pass "setup: the repair could not link the orphan into the full lost+found"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "leaked" <<<"$OUT" && fail "the failed link left a block allocated: $(grep leaked <<<"$OUT" | head -1)" ||
    pass "the failed link left no block behind"
grep -qE "cached free_data_blocks|free_blocks .*!=|aggregate" <<<"$OUT" &&
    fail "and the free counts disagree with the bitmap: $(grep -m1 -E 'cached free_data_blocks|aggregate' <<<"$OUT")" ||
    pass "and the free counts match the bitmap"
ct_exit
