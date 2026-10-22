#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub's DECIDING pass must read the inode table from the device
#
# scrub.c used to claim that cached reads were safe here: "a stale read
# can only make the scrub keep a block (never free a live one)". That is
# backwards, and it cost a corrupted directory on the test cluster.
#
# Staleness means FEWER references, not more. A cached inode record that
# predates an extent a PEER just added makes the blocks of that extent
# look referenced by nothing -- so they become candidates, survive the
# two-pass gap (both passes read the same stale cache and agree), and get
# freed out from under a live file. Same for a cached inode-BITMAP block
# that still reads "free" for an inode a peer has since allocated: the
# walk skips the inode entirely and every block it names looks leaked.
#
# Staged here with one node, because the cache is what matters and not
# who dirtied the device: a block is allocated behind the kernel's back,
# then the file's extent is grown ON THE DEVICE to cover it. The kernel
# holds a record that does not mention that block -- exactly what a peer's
# append leaves it holding -- and the scrub must not free it.
#
# Negative control: pass fresh=false to the second scrub_build_refset()
# in cetrafs_scrub_cycle() and the block is reclaimed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 scrubfresh)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubfresh)"
ct_mkfs_small "$DEV" -z 1 >/dev/null

# Fast scrub, set BEFORE the mount (the first cycle is queued with the
# interval as it reads it then).
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_secs 2
# One block at a time: a speculative run would reserve the very blocks
# this test wants to allocate behind the kernel's back.
ct_param_set alloc_run_blocks 0

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
freeb()   { sed -n 's/^free_data_blocks: //p' "$PROC"; }
cycles()  { sed -n 's/^scrub_cycles: //p' "$PROC"; }
reclaim() { sed -n 's/^scrub_reclaimed: //p' "$PROC"; }

# A file with one contiguous extent, fully persisted and then left alone
# -- nothing below touches it through the mount, so the kernel keeps the
# record it cached here.
dd if=/dev/zero of="$MNT/victim" bs=4096 count=4 conv=fsync status=none
sync
INO="$(stat -c %i "$MNT/victim")"
SHAPE="$("$IPOKE" "$IMG" extents "$INO")"
PHYS="$(echo "$SHAPE" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
LEN="$(echo "$SHAPE" | sed -n 's/^ext 0 .*len=\([0-9]*\).*/\1/p' | head -1)"
log "victim ino=$INO extent phys=$PHYS len=$LEN"
[ -n "$PHYS" ] && [ "$PHYS" != "0" ] && [ "$LEN" = "4" ] &&
    pass "setup: the victim has one 4-block extent at $PHYS" ||
    fail "setup: unexpected extent shape ($SHAPE) -- the poke below would target the wrong block"

# The block right after it, allocated in the bitmap but named by nothing
# yet: that is what the scrub is entitled to reclaim, and what it must
# STOP reclaiming once the record below names it.
DATA_START="$(echo "$("$LEAK" "$DEV" 0 0 1)" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
NEXT=$((PHYS + LEN))
OFFSET=$((NEXT - DATA_START))
"$LEAK" "$DEV" 0 "$OFFSET" 1 >/dev/null
log "allocated block $NEXT (data offset $OFFSET) behind the kernel's back"

F0="$(freeb)"; C0="$(cycles)"; R0="$(reclaim)"

# Now the device says the victim owns it too. The kernel's cached record
# still says len=4, which is precisely the stale view a peer's append
# leaves behind.
"$IPOKE" "$IMG" growext "$INO" 1 >/dev/null
AFTER="$("$IPOKE" "$IMG" extents "$INO" | sed -n 's/^ext 0 .*len=\([0-9]*\).*/\1/p' | head -1)"
[ "$AFTER" = "5" ] &&
    pass "setup: the on-disk record now covers $NEXT (len 4 -> 5) while the kernel still has len 4" ||
    fail "setup: growext did not land (len reads $AFTER) -- nothing below would mean anything"

log "waiting for 2 full scrub cycles (from $C0) ..."
DEADLINE=$((SECONDS + 90))
while [ "$(cycles)" -lt $((C0 + 2)) ]; do
    [ "$SECONDS" -lt "$DEADLINE" ] || fail "no 2 scrub cycles completed in 90s (cycles=$(cycles))"
    sleep 1
done

REC=$(( $(reclaim) - R0 ))
log "reclaimed $REC block(s) across $(( $(cycles) - C0 )) cycle(s); free $F0 -> $(freeb)"

[ "$REC" = "0" ] &&
    pass "the scrub freed nothing: its deciding pass re-read the record and saw the block referenced" ||
    fail "the scrub reclaimed $REC block(s) that an on-disk record names -- it decided on a cached inode table"

ct_umount "$MNT"
ct_exit
