#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the background scrub must not reclaim a LIVE speculative allocation run
#
# A reservation (lock.c) claims a contiguous run of blocks ahead of need:
# the bits are SET IN THE BITMAP and referenced by NO extent, and it is
# held for as long as the file stays open.
#
# That is, bit for bit, the scrub's definition of a leaked block. The
# scrub's safety argument (scrub.c's header) is "a real allocation commits
# its extent within one get_block() call, so it is referenced by the
# second pass" -- true of the block being written, false of the run behind
# it. Without the check in scrub_free_confirmed() the scrub frees a live
# run, its owner hands those blocks out anyway, and two files end up
# sharing them.
#
# The assertions below are built so the test cannot pass vacuously:
#   1. the reservation is PROVEN to exist (free count drops by the run,
#      not by the one block written) -- otherwise there is nothing to
#      reclaim and any fix "works";
#   2. a full scrub cycle is PROVEN to have run start-to-finish while the
#      run was held (scrub_cycles), rather than the test simply outrunning
#      the scrub;
#   3. only then is "nothing was reclaimed" meaningful.
#
# Negative control: drop the cetrafs_resv_covers_locked() gate in
# scrub.c's scrub_free_confirmed() and this fails with ~255 blocks
# reclaimed out from under an open file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 scrubresv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubresv)"
ct_mkfs_small "$DEV" >/dev/null

# Make the scrub run often and confirm quickly. The gap still has to
# exceed any real allocation's commit window; 2s does, by orders of
# magnitude, for a loop device.
#
# BEFORE the mount, not after: cetrafs_scrub_start() queues the first
# delayed work with the interval as it reads it at mount time, so a
# later change does not shorten the cycle already pending -- it would
# fire 30 minutes from now, and this test would sit waiting for a cycle
# that never comes (it did, on the first run).
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_secs 2

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
freeb()   { sed -n 's/^free_data_blocks: //p' "$PROC"; }
cycles()  { sed -n 's/^scrub_cycles: //p' "$PROC"; }
reclaim() { sed -n 's/^scrub_reclaimed: //p' "$PROC"; }

[ -n "$(cycles)" ] || fail "procfs has no scrub_cycles counter -- cannot prove a cycle ran"

RUN="$(cat /sys/module/cetrafs/parameters/alloc_run_blocks)"
log "alloc_run_blocks=$RUN"
[ "$RUN" -ge 32 ] || fail "alloc_run_blocks=$RUN is too small for this test to observe anything"

F0="$(freeb)"
R0="$(reclaim)"

# ---- 1. install a reservation and PROVE it exists -------------------
#
# The fd is held open by this shell for the rest of the test: dd writes
# through a dup of it, so dd exiting does NOT call ->release and the
# remainder of the run stays reserved.
exec 3>"$MNT/held"
dd if=/dev/zero bs=4096 count=1 status=none >&3
sync

F1="$(freeb)"
USED=$((F0 - F1))
log "one 4 KiB write consumed $USED blocks of free space (1 written + the reserved run)"
[ "$USED" -ge $((RUN / 2)) ] &&
    pass "a speculative run is installed and live ($USED blocks held for a 1-block write)" ||
    fail "only $USED blocks were taken: no speculative run was installed, so this test would prove nothing"

# ---- 2. let a whole scrub cycle run while it is held ----------------
#
# Two cycles, not one: a cycle already in flight when the run was
# installed would have taken its first pass BEFORE those bits were set,
# so the blocks were never candidates in it. Waiting for a second
# guarantees one complete cycle saw them set from its first pass on --
# the case that must be rejected by the fix rather than by timing.
C0="$(cycles)"
log "waiting for 2 full scrub cycles (from $C0) ..."
DEADLINE=$((SECONDS + 90))
while [ "$(cycles)" -lt $((C0 + 2)) ]; do
    [ "$SECONDS" -lt "$DEADLINE" ] || fail "no 2 scrub cycles completed in 90s (cycles=$(cycles), started at $C0)"
    sleep 1
done
log "scrub cycles completed: $(( $(cycles) - C0 ))"

# ---- 3. the assertion ------------------------------------------------
R1="$(reclaim)"
F2="$(freeb)"
log "scrub_reclaimed: $R0 -> $R1   free_data_blocks: $F1 -> $F2"

[ "$R1" -eq "$R0" ] &&
    pass "a full scrub cycle reclaimed nothing while the run was held" ||
    fail "the scrub reclaimed $((R1 - R0)) block(s) with no leak present -- it ate the live reservation"
[ "$F2" -eq "$F1" ] &&
    pass "free space is unmoved across the scrub ($F2 blocks)" ||
    fail "free space moved by $((F2 - F1)) blocks under a held reservation with no other writer"

# ---- 4. and the run IS given back on close --------------------------
#
# The mirror of the assertion above: if the blocks were simply never
# reserved, (1) would have caught it -- but this also proves the fix
# did not turn the run into a permanent leak.
exec 3>&-
sync
F3="$(freeb)"
log "after close: free_data_blocks $F2 -> $F3"
[ "$F3" -gt "$F2" ] &&
    pass "closing the file hands the unused run back ($((F3 - F2)) blocks)" ||
    fail "closing the file returned no blocks: the reservation leaked"
[ $((F0 - F3)) -le 4 ] &&
    pass "only the block actually written is still allocated ($((F0 - F3)))" ||
    fail "$((F0 - F3)) blocks still missing after close (expected ~1 for the block actually written)"

ct_umount "$MNT"
ct_fsck "$DEV" &&
    pass "fsck is clean after a scrub ran alongside a live reservation" ||
    fail "fsck found faults after a scrub ran alongside a live reservation"

ct_exit
