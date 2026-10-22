#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub must not reclaim a block that already has a free QUEUED
#
# A pending-free entry names a block whose owner has already dropped the
# extent and handed the free to this node. Until the drain applies it the
# block is bitmap-SET and referenced by NOTHING -- which is exactly the
# scrub's definition of a leak, and it is not one.
#
# Freeing it is a double free with a gap in the middle: the bit clears
# early, this node's allocator hands the block to a new file, and the
# next drain then applies the queued free to a block that is live again.
# Two files, one block. Note the hazard exists ONLY because of the scrub
# -- nothing else can clear that bit before the drain, so the allocator
# could never have handed the block out early.
#
# The discriminator is that TWO ranges are leaked and only ONE has a
# queued free. A scrub that reclaims both is broken; a scrub that
# reclaims neither is broken differently (and would pass a test that only
# checked the queued range). Only "exactly the unqueued range" is right.
#
# Negative control: drop the cetrafs_zg_pending_free_for_each() sweep from
# scrub_build_refset() and this reports both ranges reclaimed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
PENDPOKE="$(ct_helper pending_poke)"

NLEAK=40
OFF_PLAIN=100      # leaked, nothing queued  -> MUST be reclaimed
OFF_QUEUED=300     # leaked, free queued     -> MUST be left alone

IMG="$(ct_image 560 scrubq)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubq)"
ct_mkfs_small "$DEV" -z 1 >/dev/null

PROC="$(ct_procdir "$DEV")/info"
freeb()   { sed -n 's/^free_data_blocks: //p' "$PROC"; }
cycles()  { sed -n 's/^scrub_cycles: //p' "$PROC"; }
reclaim() { sed -n 's/^scrub_reclaimed: //p' "$PROC"; }

# Fast scrub, set BEFORE the mount: the first cycle is queued with the
# interval as it reads at mount time.
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_secs 2
# And a heartbeat that will not tick during the test. The drain runs on a
# tick, and a drained entry is no longer queued -- the test would then be
# asserting about an empty queue and would pass against broken code.
ct_param_set hb_interval_secs 3600

log "leak two ranges of $NLEAK blocks each, neither referenced by any inode"
"$LEAK" "$DEV" 0 "$OFF_PLAIN" "$NLEAK" >/dev/null
# The helper reports the absolute LBA; the queue entry needs it, and
# deriving it from fsck would mean piping a tool whose nonzero exit IS
# the finding (it exits nonzero precisely BECAUSE of the leak we just
# made, which aborted the first version of this suite).
QUEUED_LBA="$("$LEAK" "$DEV" 0 "$OFF_QUEUED" "$NLEAK" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
[ -n "$QUEUED_LBA" ] || fail "setup: could not learn the leaked range's absolute LBA"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "leaked" &&
    pass "setup: fsck confirms the blocks are leaked" ||
    fail "setup: fsck did not report a leak, so there is nothing for the scrub to get wrong"

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# The queue entry goes in AFTER the mount: the mount path drains too, and
# an entry queued before it would simply be gone.
"$PENDPOKE" "$IMG" add 0 "$QUEUED_LBA" "$NLEAK" >/dev/null
[ "$("$PENDPOKE" "$IMG" dump 0 | grep -c .)" -ge 1 ] &&
    pass "setup: a free is queued for the second range (lba $QUEUED_LBA +$NLEAK)" ||
    fail "setup: nothing was queued, so this test would prove nothing"

F0="$(freeb)"
C0="$(cycles)"
R0="$(reclaim)"

log "waiting for 2 full scrub cycles (from $C0) ..."
DEADLINE=$((SECONDS + 90))
while [ "$(cycles)" -lt $((C0 + 2)) ]; do
    [ "$SECONDS" -lt "$DEADLINE" ] || fail "no 2 scrub cycles completed in 90s (cycles=$(cycles))"
    sleep 1
done

REC=$(( $(reclaim) - R0 ))
GOT=$(( $(freeb) - F0 ))
log "reclaimed $REC block(s), free space moved by $GOT"

# The queue must still hold the entry: if the drain ate it, the scrub was
# never asked the question this suite exists to ask.
[ "$("$PENDPOKE" "$IMG" dump 0 | grep -c .)" -ge 1 ] &&
    pass "the queued free is still queued (the drain did not pre-empt the test)" ||
    fail "the entry was drained during the run: the scrub never faced a queued block"

[ "$REC" = "$NLEAK" ] &&
    pass "the scrub reclaimed exactly the unqueued range ($REC blocks)" ||
    fail "scrub reclaimed $REC, expected $NLEAK: $([ "$REC" -gt "$NLEAK" ] && echo 'it freed a block with a queued free -- the next drain will clear it again under a new owner' || echo 'it missed the genuine leak too')"

ct_umount "$MNT"
ct_exit
