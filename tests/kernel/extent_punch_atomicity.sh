#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch that cannot complete frees nothing
#
# A hole landing strictly inside an extent SPLITS it into two, which is
# the only case that grows the extent array -- and the array is one
# external leaf block with nowhere to chain, so a split can genuinely run
# out of room.
#
# cetrafs_leaf_array_punch() discovered that too late. It freed an
# entry's overlapping blocks and only then checked whether the split-off
# tail would fit, returning -ENOSPC without ever writing back *entries or
# *out_freed. The blocks were gone from the bitmap, the array was
# half-edited, and the caller either published it with a stale entry
# count or discarded the edit and left the on-disk leaf still pointing at
# blocks the allocator had taken back. Either way one physical block ends
# up reachable from two files.
#
# It now decides up front -- counting the splits a punch would need
# before freeing anything -- so the operation is all-or-nothing.
#
# The file is built to fill the leaf: strided single-block writes each
# become their own extent (insert() merges only when logical AND physical
# are both contiguous), plus one contiguous run a hole can land inside.
#
# Measured discrimination: with the dry run removed, two assertions fail
# -- the refused punch frees two blocks, and fsck names the result
# exactly ("block 1444 is referenced by an inode but marked FREE -- it
# can be handed out again"). That is the corruption: the allocator will
# give those blocks to a second file while this one still points at them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 epa)"
MNT="$(ct_mnt epa)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

F="$MNT/frag"
# Asked for, never hardcoded: this number changed when v0x000F gave the
# leaf a tail checksum, and a test carrying the old value does not just
# fail -- it stops building the full leaf this suite exists to test.
MAXLEAVES="$("$(ct_helper inode_block_poke)" "$DEV" maxleaves)"
log "building a file whose extent leaf is full ($MAXLEAVES entries)"
python3 - "$F" "$MAXLEAVES" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
blk = b'x' * 4096
# (max-1) strided single-block extents + one 8-block run = exactly
# CETRAFS_EXT_BLOCK_MAX_LEAVES. The leaf is then full, so a split has
# nowhere to go -- which is the case under test.
maxleaves = int(sys.argv[2])
for i in range(maxleaves - 1):
    os.pwrite(fd, blk, i * 2 * 4096)
base = 700 * 4096
for i in range(8):
    os.pwrite(fd, blk, base + i * 4096)
os.fsync(fd)
os.close(fd)
PY
sync
SUM_BEFORE="$(md5sum "$F" | cut -d' ' -f1)"
FREE_BEFORE="$(stat -f -c '%f' "$MNT")"
pass "punch atomicity: built a file with $(stat -c '%b' "$F") 512-byte blocks"

log "punching a hole strictly inside the trailing run"
PUNCH_RC=0
fallocate --punch-hole --keep-size -o $((702 * 4096)) -l $((2 * 4096)) "$F" 2>/dev/null || PUNCH_RC=$?
sync

if [ "$PUNCH_RC" = "0" ]; then
    pass "punch atomicity: the split fitted and the punch succeeded"
    ZERO="$(python3 -c "
import sys
d=open(sys.argv[1],'rb');d.seek(702*4096)
print('yes' if d.read(2*4096)==bytes(2*4096) else 'no')" "$F")"
    [ "$ZERO" = "yes" ] && pass "punch atomicity: the punched range reads as zeros" ||
        fail "punch atomicity: the punched range is not zero"
else
    pass "punch atomicity: the punch was refused (rc=$PUNCH_RC) -- the interesting case"
    [ "$(md5sum "$F" | cut -d' ' -f1)" = "$SUM_BEFORE" ] &&
        pass "punch atomicity: the file's contents are unchanged after the refusal" ||
        fail "punch atomicity: a REFUSED punch changed the file's contents"
    [ "$(stat -f -c '%f' "$MNT")" = "$FREE_BEFORE" ] &&
        pass "punch atomicity: no blocks were freed by the refused punch" ||
        fail "punch atomicity: a refused punch freed blocks ($FREE_BEFORE -> $(stat -f -c '%f' "$MNT"))"
fi

log "checking the filesystem is coherent either way"
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if echo "$FSCK_OUT" | grep -q "cetrafs fsck: OK"; then
    pass "fsck: clean after the punch"
else
    fail "fsck: $(echo "$FSCK_OUT" | grep -iE 'ERR|WARN' | head -2 | tr '\n' ' ')"
fi

ct_exit
