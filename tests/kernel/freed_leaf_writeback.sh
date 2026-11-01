#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a freed extent leaf this node still holds dirty never reaches a block a peer now owns
#
# A regular file's extent leaf is deliberately left DIRTY when an
# allocation changes it, to be written at the next durability boundary
# (close, fsync, writeback): journaling it per guest write made a VM
# image unusably slow. Truncate, punch and defrag then free the old
# tree's leaves and interiors through the bitmap -- and nothing told the
# buffer cache, so the block went back still dirty here.
#
# On ONE node that is covered by the kernel: a block newly mapped as
# file data has its buffer-cache aliases cleaned
# (clean_bdev_aliases(), from __block_write_begin and direct I/O).
# Nothing like that reaches across nodes. Once the Block Group goes back
# and a peer allocates the block, this node's writeback puts the dead
# leaf on top of the peer's data.
#
# The test frees a dirty leaf, empties the volume so the leaf's Block
# Group is released, plays the peer by writing the block on the device,
# and then lets this node write back.
#
# DISCRIMINATION (measured on the unfixed code): the peer's block reads
# back as this node's dead extent leaf.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
MAP="$(ct_helper bg_map)"
FREE_MARK=65535

DEV="$(ct_dev 1700 freedleaf)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt freedleaf)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
compress_timing
ct_param_set alloc_run_blocks 0 # one block per allocation: fragmentation on demand
ct_param_set bg_release_off 1   # nothing goes back until the stage is set
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Past the first Block Group, so F lands in one that can be given back.
dd if=/dev/zero of="$MNT/pad" bs=1M count=600 status=none
sync

# F, fragmented past the inline slots: its blocks interleave with H's.
python3 - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
f = os.open(m + "/F", os.O_RDWR | os.O_CREAT, 0o644)
h = os.open(m + "/H", os.O_RDWR | os.O_CREAT, 0o644)
for i in range(12):
    os.pwrite(f, b'F' * 4096, i * 4096); os.fsync(f)
    os.pwrite(h, b'H' * 4096, i * 4096); os.fsync(h)
os.close(f); os.close(h)
PY
sync
FINO="$(stat -c %i "$MNT/F")"
LEAF="$(sed -n 's/^leaf=//p' <<<"$("$IPOKE" "$BACK" extents "$FINO")")"
LBG="$("$MAP" "$DEV" | awk -v l="$LEAF" '$1 == "bg" {split($4,a,"="); if (a[2] + 0 <= l + 0) b = $2} END {print b}')"
[ -n "$LEAF" ] && [ "${LBG:-0}" != 0 ] && pass "F is depth 1, its leaf at block $LEAF in Block Group $LBG" ||
    { fail "setup: F's leaf '$LEAF' is not in a releasable Block Group ('$LBG')"; ct_exit; }

# The leaf changed by an append and left dirty, then freed by truncate --
# no sync anywhere from here on, or the leaf is written while still ours.
python3 - "$MNT" <<'PY'
import os, sys
f = os.open(sys.argv[1] + "/F", os.O_RDWR)
os.pwrite(f, b'A' * 4096, 40 * 4096)
os.ftruncate(f, 0)
os.close(f)
PY
rm -f "$MNT/F" "$MNT/H" "$MNT/pad"
ct_param_set bg_release_off 0
bg_owner() { "$MAP" "$DEV" | awk -v b="$1" '$1 == "bg" && $2 == b {split($3,a,"="); print a[2]}'; }
if wait_for 30 '[ "$(bg_owner '"$LBG"')" = '"$FREE_MARK"' ]' 2>/dev/null; then
    pass "Block Group $LBG, holding the freed leaf, was given back"
else
    fail "setup: Block Group $LBG was never released (owner $(bg_owner "$LBG")) -- the handover is not exercised"
    ct_exit
fi

# The peer: claims the Block Group and writes its data into that block.
python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b'\xab' * 4096, int(sys.argv[2]) * 4096)
os.fsync(fd)" "$BACK" "$LEAF"

# This node writes back whatever it still holds dirty.
sync
ct_umount "$MNT"
got="$(python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
d = os.pread(fd, 4096, int(sys.argv[2]) * 4096)
print('intact' if d == b'\xab' * 4096 else 'overwritten')" "$BACK" "$LEAF")"
[ "$got" = intact ] && pass "the peer's block survived this node's writeback" ||
    fail "this node wrote its freed, dead extent leaf over block $LEAF after a peer took it"

ct_exit
