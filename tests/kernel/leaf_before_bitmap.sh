#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an extent leaf that writeback flushes early never names a block the device still reads as free
#
# Rule 8, through background writeback. A regular file's extent-tree
# blocks are edited in place and left DIRTY in the block device's cache
# until the close/fsync boundary -- and the allocation bitmap bit for the
# block a new extent names is set with sync=false, also only in cache.
# Nothing ordered the two: the block device's own flusher (30 s dirty
# expiry, memory pressure, sync of the bdev) may write the leaf first.
# A crash then leaves a leaf naming a block the bitmap calls FREE, and
# the allocator hands it to another file.
#
# The flusher writing the leaf and nothing else is reproduced exactly,
# without a crash rig: a copy of the backing file is the device as it
# stands (no unwritten buffer in it); a buffered read of the loop device
# returns the kernel's cached, dirty leaf; writing that leaf into the
# copy is the state the early writeback leaves. fsck on it.
#
# COST of the fix (counted at the loop device): one synchronous bitmap
# write per speculative run -- 65 extra writes for a 64 MiB stream into
# an open spilled file, against 1 before. Not one per block.
#
# DISCRIMINATION (measured on the unfixed code): all 4 rounds -- 3 new
# extents, 1 merge into the last extent -- leave a leaf naming a block
# the device reads as FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAF_POKE="$(ct_helper leaf_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 leafbm)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt leafbm)"
SNAP="$(ct_tmp leafbm-snap)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: *//p' "$(ct_procdir "$DEV")/info")"
[ -n "$NID" ] || { fail "setup: no this_node_id in procfs"; ct_exit; }

# The device as an early writeback would leave it: the backing file, plus
# the kernel's cached leaf. Our own row is marked departed in the copy
# only so fsck does not spend 35 s watching it for a heartbeat.
snapshot_verdict() { # <label> -> sets bad
    cp --sparse=always "$BACK" "$SNAP"
    dd if="$DEV" of="$SNAP" bs=4096 skip="$LEAF" seek="$LEAF" count=1 conv=notrunc status=none
    "$NODE_POKE" "$SNAP" "$NID" 0 bb 0 >/dev/null
    local sl frc=0 out
    sl="$(ct_loop "$SNAP")"
    out="$(ct_fsck "$sl" 2>&1)" || frc=$?
    losetup -d "$sl"
    rm -f "$SNAP"
    [ "$frc" -le 1 ] || { fail "setup $1: fsck of the snapshot gave no verdict (rc=$frc): $(tail -1 <<<"$out")"; return; }
    if grep -q 'marked FREE' <<<"$out"; then
        bad=$((bad + 1))
        log "$1: $(grep 'marked FREE' <<<"$out" | head -1)"
    fi
}
leaf_is_dirty() { ! cmp -s <(dd if="$DEV" bs=4096 skip="$LEAF" count=1 status=none) \
    <(dd if="$BACK" bs=4096 skip="$LEAF" count=1 status=none); }

# A spilled (depth-1) file: one extent per block, fillers in between.
for i in $(seq 0 7); do
    dd if=/dev/urandom of="$MNT/f" bs=4096 seek="$i" count=1 conv=notrunc status=none
    printf x >"$MNT/filler$i"
done
sync
INO="$(stat -c %i "$MNT/f")"
LEAF="$("$LEAF_POKE" "$BACK" leaf "$INO" 2>/dev/null || true)"
[ -n "$LEAF" ] && [ "$LEAF" -gt 0 ] 2>/dev/null && pass "setup: the file is spilled, leaf at block $LEAF" ||
    { fail "setup: the file did not spill to an external leaf ('$LEAF')"; ct_exit; }

# The window exists only while the file is OPEN: close and fsync flush
# the bitmaps, then the tree. A VM image is open for its whole life.
exec 7<>"$MNT/f"
bad=0
for round in 1 2 3; do
    # A filler first, so the append is a new extent; no close, no fsync:
    # the leaf and the bitmap are both dirty in cache.
    printf y >"$MNT/gap$round"
    python3 -c 'import os,sys; os.pwrite(int(sys.argv[1]), os.urandom(4096), int(sys.argv[2]) * 4096)' 7 $((7 + round))
    leaf_is_dirty || { fail "setup round $round: the cached leaf already matches the device"; continue; }
    snapshot_verdict "round $round (new extent)"
done
# The VM-image shape: speculative runs on (the default), contiguous
# appends merging into the leaf's last extent. The run's bits are set
# all at once when it is reserved.
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 7 # start this round from a clean device
ct_param_set alloc_run_blocks 256
for blk in 12 13 14 15; do
    python3 -c 'import os,sys; os.pwrite(int(sys.argv[1]), os.urandom(4096), int(sys.argv[2]) * 4096)' 7 "$blk"
done
if leaf_is_dirty; then
    snapshot_verdict "merge round"
else
    fail "setup merge round: the cached leaf already matches the device"
fi
exec 7>&-
[ "$bad" = 0 ] && pass "a leaf written early never names a block the device reads as free (4 rounds)" ||
    fail "$bad of 4 rounds: the early-written leaf names a block whose bitmap bit never reached the device"

ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
