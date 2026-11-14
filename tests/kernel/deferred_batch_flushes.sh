#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back tree batch issues two cache flushes, not three
#
# A regular file's extent-tree blocks are written at a durability boundary
# as one journal batch (journal.c cetrafs_journal_write_deferred()). It
# used to flush three times: before the entries (the bitmaps and the data
# first), after the entries, and after the targets, the last so that the
# entries could be consumed. The consume now waits for the NEXT batch's
# first flush, which is issued after this batch's targets completed: the
# flush after the targets moves there, and the entries stay live (and
# replayable) until then. A preallocated image's write pays for every
# flush of its boundary, which is what made it run at a seventh of a
# written one's speed (TODO: P8(b)).
#
# Procfs deferred_batches and deferred_batch_flushes count the batches and
# the flushes they issued. Over rounds of fdatasync into a fallocated file
# (every round converts blocks, so every round writes a batch):
#   1. the flushes per batch are 2 (the first flush of each batch and the
#      one after its entries);
#   2. control deferred_batch_after_flush=1 (TEST ONLY) restores the flush
#      after the targets, and the count goes back to 3 per batch.
# Setup: the workload must have produced batches; a zero is not a pass.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/deferred_batch_after_flush ] || { skip "deferred_batch_after_flush is missing"; ct_exit; }
MNT="$(ct_mnt dbf)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set deferred_batch_after_flush 0

DEV="$(ct_loop "$(ct_image 560 dbf1)")"
# A journal: the batch path under test is the journaled one (mkfs -J 0
# writes its targets in place with no entries at all).
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
[ -r "$PROC" ] || { skip "no procfs info for the mount"; ct_exit; }

counter() { sed -n "s/^$1: //p" "$PROC"; }

# rounds <name>: 64 preallocated blocks, then 10 rounds of 4 random
# blocks written and fdatasynced.
rounds() {
    python3 - "$MNT/$1" <<'PY'
import os, random, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
os.posix_fallocate(fd, 0, 64 * 4096)
random.seed(5)
for r in range(1, 11):
    for b in random.sample(range(64), 4):
        os.pwrite(fd, (b"R%03dB%03d" % (r, b)) * 512, b * 4096)
    os.fdatasync(fd)
os.close(fd)
PY
}

# measure <file> <knob>: prints "<batches> <flushes>" the rounds added.
measure() {
    local b0 f0 b1 f1
    echo "$2" >/sys/module/cetrafs/parameters/deferred_batch_after_flush
    b0="$(counter deferred_batches)"
    f0="$(counter deferred_batch_flushes)"
    rounds "$1"
    b1="$(counter deferred_batches)"
    f1="$(counter deferred_batch_flushes)"
    echo "$((b1 - b0)) $((f1 - f0))"
}

read -r B FL <<<"$(measure shipped 0)"
echo 0 >/sys/module/cetrafs/parameters/deferred_batch_after_flush
[ "$B" -gt 0 ] && pass "setup: the rounds wrote $B held-back tree batches" ||
    { fail "setup: the rounds wrote no held-back tree batch -- nothing to count"; ct_exit; }
[ "$FL" = $((2 * B)) ] && pass "as shipped: $FL flushes for $B batches, 2 per batch" ||
    fail "as shipped: $FL flushes for $B batches (want 2 per batch): the flush after the targets is still issued"

read -r CB CFL <<<"$(measure control 1)"
echo 0 >/sys/module/cetrafs/parameters/deferred_batch_after_flush
[ "$CFL" = $((3 * CB)) ] && pass "control: with the after-targets flush restored, $CFL flushes for $CB batches" ||
    fail "control: $CFL flushes for $CB batches -- the counter does not see the after-targets flush"

ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$out" && fail "fsck: $(grep '^ERR' <<<"$out" | head -2)" || pass "fsck clean"
ct_exit
