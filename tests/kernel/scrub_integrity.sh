#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub reclaims EXACTLY the leaked blocks and never a live one,
# with live files written THROUGHOUT -- content + accounting verified
#
# scrub.sh proves the scrub reclaims a crafted leak on an otherwise
# static volume. This adds the two things a reclaimer most needs
# guarded: (1) it must not free a block a LIVE file holds -- verified by
# hashing real files that stay put while the scrub runs, and again after
# more files are written concurrently with it; (2) the books must
# balance -- free space recovers by exactly the leak, never more, and
# fsck agrees.
#
# Over-reclaiming is the catastrophic direction (a live block handed to
# the next allocation = cross-file corruption), so the content hashes are
# the real assertion; scrub_reclaimed and fsck are the corroborators.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
NLEAK=64
IMG="$(ct_image 560 scrubint)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubint)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" -z 1 >/dev/null

info() { cat "/proc/fs/cetrafs/$PROC_DEV/info"; }
free_blocks() { info | sed -n 's/^free_data_blocks: //p'; }
reclaimed() { info | sed -n 's/^scrub_reclaimed: //p'; }

# ---- write LIVE files first, record hashes, find a safe leak offset ----
ct_param_set scrub 0   # off while we lay things out
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
declare -A LHASH CHHASH
NLIVE=10
for n in $(seq 1 "$NLIVE"); do
    dd if=/dev/urandom of="$MNT/live_$n" bs=1M count=3 status=none 2>/dev/null
    LHASH[$n]="$(sha256sum "$MNT/live_$n" | cut -d' ' -f1)"
done
sync
ct_umount "$MNT"

# Leak blocks in BG 0 at an offset chosen to sit PAST everything the live
# files and metadata used, so the poke invents a genuine leak rather than
# colliding with a real reference. The data region on a freshly filled
# 560 MiB -z 1 volume still has room high up; 110000 is comfortably past
# the ~7680 blocks the live files occupy and the low metadata.
OFFSET=110000
"$LEAK" "$DEV" 0 "$OFFSET" "$NLEAK" >/dev/null
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "leaked" <<<"$FSCK_OUT" &&
    pass "setup: $NLEAK blocks leaked past the live files, fsck confirms" ||
    fail "setup: fsck did not report the crafted leak: $(grep -iE 'err|warn' <<<"$FSCK_OUT" | head -1)"

# ---- mount with a fast scrub; it reclaims the leak with live files present ----
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BEFORE="$(free_blocks)"
# scrub_reclaimed is module-global and cumulative (the negative control
# below already measures a delta for that reason); the main assertion
# read it absolutely and so was correct only while this suite happened to
# run before any other scrub in the same module load. Baseline first,
# then arm -- scrub.sh is where that luck ran out.
REC_BASE="$(reclaimed)"
ct_param_set scrub 1

# While the scrub runs its cycles, write MORE files -- so the deciding
# pass has in-flight allocations to (correctly) spare, and the live set
# it must not touch is growing.
for n in $(seq 1 8); do
    dd if=/dev/urandom of="$MNT/churn_$n" bs=1M count=2 status=none 2>/dev/null || true
    CHHASH[$n]="$(sha256sum "$MNT/churn_$n" | cut -d' ' -f1)"
done
wait_for 40 '[ "$(( $(reclaimed) - '"$REC_BASE"' ))" -gt 0 ]' || true
REC="$(( $(reclaimed) - REC_BASE ))"
AFTER="$(free_blocks)"

# ---- the reclaim was exact ----
[ "$REC" = "$NLEAK" ] &&
    pass "scrub reclaimed EXACTLY the $NLEAK leaked blocks (not one live block over)" ||
    fail "scrub_reclaimed=$REC, expected $NLEAK -- over-reclaim is cross-file corruption, under is a missed leak"

# ---- live + churn files are byte-identical (nothing live was freed) ----
bad=0
for n in $(seq 1 "$NLIVE"); do
    [ "$(sha256sum "$MNT/live_$n" | cut -d' ' -f1)" = "${LHASH[$n]}" ] || { bad=$((bad+1)); log "live_$n changed"; }
done
for n in $(seq 1 8); do
    [ "$(sha256sum "$MNT/churn_$n" | cut -d' ' -f1)" = "${CHHASH[$n]}" ] || { bad=$((bad+1)); log "churn_$n changed"; }
done
[ "$bad" -eq 0 ] &&
    pass "every live file is byte-identical after the scrub (no live block was reclaimed)" ||
    fail "$bad file(s) corrupted -- the scrub freed a block still in use"

ct_umount "$MNT"

# ---- accounting: fsck clean, and free recovered by exactly the leak ----
ct_fsck "$DEV" >/dev/null 2>&1 &&
    pass "fsck clean after the scrub (no leak remains, counts match the bitmap)" ||
    fail "fsck still reports a problem: $(ct_fsck "$DEV" 2>&1 | grep -iE 'leak|err' | head -1)"

# ---- discrimination: with the scrub OFF the leak must persist ----
# Fresh volume (the first run's files would collide with a re-poke), and
# a DELTA on scrub_reclaimed (it is a cumulative module-global counter,
# not per-mount) -- off means it must not move and the leak must stay.
ct_param_set scrub 0
ct_mkfs_small "$DEV" -z 1 >/dev/null
"$LEAK" "$DEV" 0 "$OFFSET" "$NLEAK" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
REC_BEFORE="$(reclaimed)"   # procfs exists only while mounted
sleep 5                      # a cycle would have run by now if enabled
REC_DELTA="$(( $(reclaimed) - REC_BEFORE ))"
ct_umount "$MNT"
LEFT="$(ct_fsck "$DEV" 2>&1 | grep -c "referenced by no inode" || true)"
{ [ "$REC_DELTA" = 0 ] && [ "$LEFT" -gt 0 ]; } &&
    pass "negative control: with the scrub disabled the leak is NOT reclaimed (no reclaim, fsck still flags it)" ||
    fail "negative control: leak vanished with the scrub off (reclaim delta=$REC_DELTA, fsck leak lines=$LEFT) -- something else is reclaiming"

ct_exit
