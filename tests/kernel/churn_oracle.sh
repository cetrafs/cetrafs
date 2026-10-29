#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# randomized concurrent churn, checked against a content oracle
#
# The gap this fills
# ------------------
# Every other suite under tests/kernel/ proves one named behaviour. Two
# corruptions still shipped past the lot of them in a single week:
#
#   * a defrag abort that freed blocks it had ALREADY committed, so the
#     allocator handed one block to a second file (cross-file overlap);
#   * a torn read of an inode record against a concurrent publish, which
#     dropped whole extents out of files that had been written and
#     fsync'd -- a 223-block hole, and a filesystem that fsck called
#     perfectly consistent, because it WAS consistent. Just wrong.
#
# Neither was reachable from a serial scripted workload, and the second
# was invisible to fsck by construction. What finds that class is a
# workload that runs several writers at once, forces the allocator to
# hand out freed space again, and can say what every byte of every file
# is supposed to be. tests/helpers/churn_io.c is the oracle; this suite
# is the workload and the six gates around it.
#
# Discrimination
# --------------
# This suite's "negative control" is history, not an injected fault: it
# is checked in alongside the two fixes it would have caught, and both
# were confirmed to reproduce under it before they were fixed. It is a
# NET, not a proof -- today's bugs showed at roughly 1-in-5 and 1-in-15
# fills -- so the short run here is the gate and tests/stress/churn.sh
# is where the probability actually accumulates before a release.
#
# Knobs (all optional): CHURN_SEED CHURN_ACTORS CHURN_SECS CHURN_ROUNDS
# CHURN_FILES CHURN_MAXBLK. The seed is printed on every run and replays
# the op stream (not the interleaving).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SEED="${CHURN_SEED:-$RANDOM$$}"
ACTORS="${CHURN_ACTORS:-4}"
SECS="${CHURN_SECS:-20}"
ROUNDS="${CHURN_ROUNDS:-2}"
FILES="${CHURN_FILES:-24}"
MAXBLK="${CHURN_MAXBLK:-384}"
# CHURN_SCRUB=0 runs the identical workload with the background scrub
# off. Not a way to make the suite pass -- a bisection handle: it says
# whether a corruption the oracle reports needs the scrub at all.
SCRUB="${CHURN_SCRUB:-1}"
# Same idea for the online defragmenter: CHURN_DEFRAG=0 says whether a
# corruption needs it.
DEFRAG="${CHURN_DEFRAG:-1}"
# CHURN_PRESSURE=0 drops the sync/drop_caches loop. Each actor owns its
# files and works on them one op at a time, so writeback is the ONLY
# thing that touches an inode concurrently with its owner -- this says
# whether a corruption needs that.
PRESSURE="${CHURN_PRESSURE:-1}"

CHURN="$(ct_helper churn_io)"
# Disk-backed, not /tmp: a round deliberately runs the volume to ENOSPC,
# and a sparse image on a ~1 GiB tmpfs would hit the TMPFS's limit first
# -- which terminates the fill for a reason that has nothing to do with
# the filesystem under test (bg_release_empty learned this the hard way).
DEV="$(ct_big_dev 2048 churn)"
MNT="$(ct_mnt churn)"
# The oracle's state must NOT live on the filesystem it is checking.
STATE="$(mktemp -d "${CT_BIG_DIR:-/root}/cetrafs-churn-state-XXXXXX")"
PRESSURE_FLAG="$STATE/.pressure"

log "seed=$SEED actors=$ACTORS rounds=$ROUNDS secs=$SECS files=$FILES maxblk=$MAXBLK"

# ---------------------------------------------------------------- arming
# Everything that only runs in the background is turned UP, because a
# background worker that never fires during the test is a worker the
# test does not cover. The scrub's real interval is 30 minutes: left
# alone it would never run inside a round, and the leak it reports is
# precisely the signature the torn-read bug left behind.
ct_param_set alloc_shadow 1 # cache-immune double-alloc detector (pre-mount: allocated at fill_super)
ct_param_set auto_defrag "$DEFRAG"
ct_param_set auto_defrag_min_extents 2
ct_param_set auto_defrag_min_pct 1
case "$SCRUB" in 2) ct_param_set scrub 0 ;; *) ct_param_set scrub "$SCRUB" ;; esac
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_secs 2

ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
if [ "$DEFRAG" = 1 ]; then
    echo "defrag on" >"$PROC/controls"
    echo "auto_defrag on" >"$PROC/controls"
else
    echo "defrag off" >"$PROC/controls"
fi
mkdir -p "$MNT"/d0 "$MNT"/d1 "$MNT"/d2 "$MNT"/d3

tmark() { echo "PHASE $*" > /sys/kernel/tracing/trace_marker 2>/dev/null || true; }
scrub_cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }
scrub_reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }

# Keep the evidence when something breaks: the image, the oracle state
# and the per-actor op ring are what turn "a block was wrong" into a
# diagnosis, and a cleanup trap would delete all three.
KEEP="${CT_BIG_DIR:-/root}/cetrafs-churn-FAILED"
keep_evidence() {
    rm -rf "$KEEP"
    mkdir -p "$KEEP"
    cp -a "$STATE" "$KEEP/state" 2>/dev/null || true
    # The IMAGE too: the oracle state names what every byte SHOULD be,
    # but only the image says what the extent tree actually holds -- the
    # first amd64 corruption (a lost extend: size and tail blocks gone)
    # was undiagnosable without it, because the op ring had rotated and
    # the cleanup trap had deleted the volume (2026-10-29).
    if [ -n "${DEV:-}" ]; then
        BACK="$(losetup -nO BACK-FILE "$DEV" 2>/dev/null || true)"
        [ -n "$BACK" ] && cp --sparse=always "$BACK" "$KEEP/image" 2>/dev/null ||
            dd if="$DEV" of="$KEEP/image" bs=4M status=none 2>/dev/null || true
    fi
    log "evidence kept in $KEEP (replay with CHURN_SEED=$SEED)"
}

# ---------------------------------------------------- verification gates
verify_actors() { # <label>
    local label="$1" i bad=0 out
    for i in $(seq 0 $((ACTORS - 1))); do
        if ! out="$("$CHURN" verify "$MNT" "$STATE" "$i" 2>&1)"; then
            bad=$((bad + 1))
            echo "$out"
        fi
    done
    if [ "$bad" = 0 ]; then
        pass "every file is byte-exact $label"
    else
        fail "$bad actor(s) have corrupted or missing data $label"
        keep_evidence
    fi
}

pressure_start() {
    [ "$PRESSURE" = 0 ] && { PRESSURE_PID=""; return 0; }
    touch "$PRESSURE_FLAG"
    (
        local n=0
        while [ -e "$PRESSURE_FLAG" ]; do
            sync
            n=$((n + 1))
            # Writeback racing a publish is what tore the inode record;
            # dropping the page cache mid-run forces reads to come back
            # off the device instead of out of a page that happens to
            # still be right.
            [ $((n % 7)) = 0 ] && echo 1 >/proc/sys/vm/drop_caches
            sleep 0.2
        done
    ) &
    PRESSURE_PID=$!
}
pressure_stop() {
    [ -z "${PRESSURE_PID:-}" ] && return 0
    rm -f "$PRESSURE_FLAG"
    wait "$PRESSURE_PID" 2>/dev/null || true
}

# ------------------------------------------------------------- the rounds
C0="$(scrub_cycles)"
R0="$(scrub_reclaimed)"

for round in $(seq 1 "$ROUNDS"); do
    tmark "round$round-start"
    log "round $round/$ROUNDS: $ACTORS actors for ${SECS}s"
    pressure_start
    PIDS=""
    for a in $(seq 0 $((ACTORS - 1))); do
        CHURN_DISABLE="${CHURN_DISABLE:-}" \
            "$CHURN" churn "$MNT" "$STATE" "$SEED" "$a" "$SECS" "$FILES" "$MAXBLK" >"$STATE/a$a.out" 2>&1 &
        PIDS="$PIDS $a:$!"
    done
    # Wait on the ACTOR pids by name. A bare `wait` would also wait on
    # the pressure loop, which never exits on its own -- that mistake
    # once wedged a reproducer for nine hours.
    failed=""
    for p in $PIDS; do
        if ! wait "${p#*:}"; then failed="$failed ${p%%:*}"; fi
    done
    pressure_stop

    if [ -z "$failed" ]; then
        pass "round $round: all $ACTORS actors finished with every mid-run verify clean"
    else
        fail "round $round: actor(s)$failed hit a content mismatch DURING the run"
        for a in $failed; do sed -n '1,40p' "$STATE/a$a.out"; done
        keep_evidence
    fi

    # Force the allocator to hand out freed space rather than virgin
    # space: cross-file overlap is only observable once a block gets a
    # SECOND owner.
    tmark "round$round-squeeze"
    log "round $round: squeezing to ENOSPC to force block reuse"
    dd if=/dev/zero of="$MNT/filler" bs=1M status=none 2>/dev/null || true
    sync
    rm -f "$MNT/filler"
    sync
done

# ------------------------------------------------------------- gate 1 & 2
verify_actors "after the churn (warm)"
echo 3 >/proc/sys/vm/drop_caches
verify_actors "after drop_caches (read back off the device)"

# --------------------------------------------------------------- gate 3
# The one that catches a publish that never reached the platter: the
# torn-read bug lost extents that a warm read still served out of the
# page cache.
# The allocator shadow is an in-core bitmap built EMPTY at mount, so it
# only knows about allocations made during the current mount. Everything
# allocated before this remount is, to it, untracked -- and the scrub
# freeing a leaked block from that era then reports FREE-OF-UNTRACKED
# about a block whose on-disk bitmap bit is perfectly legitimate. Mark
# the log here so gate 6 below judges the detectors only over the window
# where they can actually be right.
tmark "remount"
# CHURN_FSCK_MID=1: fsck the device at the remount boundary, BEFORE the
# quiet window -- so "did the churn itself strand blocks on disk?" can
# be answered identically in every arm, scrub or no scrub.

SHADOW_MARK="$(dmesg_mark 2>/dev/null || date +%s)"
ct_umount "$MNT"
# CHURN_SNAP=<path>: snapshot the raw image at the remount boundary --
# post-churn, pre-scrub, unmounted. One dirty image, restored per
# experiment, replaces re-rolling a 2-minute randomized churn for every
# question asked of this state.
if [ -n "${CHURN_SNAP:-}" ]; then
    cp --sparse=always "$(losetup -nO BACK-FILE "$DEV" 2>/dev/null || true)" "$CHURN_SNAP" 2>/dev/null ||
        dd if="$DEV" of="$CHURN_SNAP" bs=4M status=none
    log "image snapshotted to $CHURN_SNAP"
fi
if [ "${CHURN_FSCK_MID:-0}" = 1 ]; then
    MIDOUT="$(ct_fsck "$DEV" 2>&1 || true)"
    MIDLEAK="$(grep -oE "[0-9]+ leaked" <<<"$MIDOUT" | head -1 || true)"
    log "MID-FSCK at the remount boundary: ${MIDLEAK:-0 leaked}"
fi
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
verify_actors "after an unmount/remount (durable)"

# --------------------------------------------------------------- gate 4
# The scrub must have actually RUN -- otherwise anything it is credited
# with below is an assumption. The QUIET WINDOW gives it a verdict: the
# scrub abandons any Block Group that saw an allocation since it
# gathered its evidence (cetrafs_sb_info.bg_alloc_seq), so with the
# actors stopped its cycles run to completion.
#
# This gate deliberately does NOT assert scrub_reclaimed == 0. It did
# once, and the assertion was wrong at its premise: a delete can leave
# an allocated nlink=0 inode behind BY DESIGN (open-at-delete residue --
# the same state fsck reports as "deleted but not yet reclaimed"), and
# scrub_reclaim_orphan_inodes() + the block passes collecting those
# blocks is the scrub doing its job, not the churn leaking. A day was
# spent proving the "leak" was exactly this residue: a boundary snapshot
# held 4 orphans owning 126 blocks; a real scrub pass reclaimed exactly
# 126 and fsck was clean; with the scrub off the same image kept its
# orphans and fsck STILL reported 0 leaked (2026-10-28).
# The real leak question is asked by gate 5b below -- fsck's own
# bitmap-vs-references sweep, which counts an orphan's blocks as
# referenced and therefore fails only on a GENUINE leak -- and by the
# no-orphans-remain assertion here, which fails if the scrub stops
# doing the reclaim this gate once misread.
tmark "quiet-window-start"
[ "$SCRUB" = 2 ] && { ct_param_set scrub 1; log "SCRUB=2: scrub armed ONLY for the quiet window"; }
log "quiet window: no I/O, so the scrub reaches a verdict instead of abandoning"
QC="$(scrub_cycles)"
wait_for 60 '[ "$(( $(sed -n "s/^scrub_cycles: //p" "'"$PROC"'/info") - '"$QC"' ))" -ge 2 ]' ||
    log "note: fewer than two quiet cycles elapsed"

CYCLES=$(($(scrub_cycles) - C0))
RECLAIMED=$(($(scrub_reclaimed) - R0))
if [ "$SCRUB" = 0 ]; then
    skip "scrub disabled for this run (CHURN_SCRUB=0) -- its gates say nothing"
else
[ "$CYCLES" -ge 2 ] &&
    pass "the background scrub ran $CYCLES cycle(s) during the churn" ||
    fail "the scrub ran $CYCLES cycle(s) -- it never fired, so it proves nothing here"
log "the scrub reclaimed $RECLAIMED block(s) -- deleted-file residue, judged by gates 4b/5b"
fi

# --------------------------------------------------------------- gate 5
# CHURN_SETTLE: idle seconds before the unmount. The quiet window above
# ends as soon as the scrub has run its cycles, which is FAR sooner than
# the 60s timeout a scrub-off run waits out -- so the two arms gave the
# deferred-free machinery wildly different amounts of time to finish,
# and the leak count was reading that difference, not a leak.
SETTLE="${CHURN_SETTLE:-0}"
if [ "$SETTLE" != 0 ]; then
    log "settling ${SETTLE}s before the unmount (deferred frees)"
    sleep "$SETTLE"
fi
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
[ "$FSCK_RC" = 0 ] &&
    pass "fsck is clean after the churn (no overlap, counts match the bitmaps)" ||
    { fail "fsck reports a problem after the churn: $(grep -m2 -iE 'ERR|leaked|overlap' <<<"$FSCK_OUT" | tr '\n' ' ')"; keep_evidence; }

# --------------------------------------------------------------- gate 5b
# fsck REPORTS a leak and deliberately does not fail on one ("a leak to
# report, not a corruption to fail on" -- fsck.c), so gate 5's exit code
# is blind to exactly the fault gate 4 exists for. Gate 4 can only speak
# when the scrub is armed; this one is the same question asked of the
# on-disk bitmaps, and it is the only one that still works with
# CHURN_SCRUB=0. Without it a leak hides from the whole suite whenever
# the scrub is off.
log "fsck content line: $(grep '^  content:' <<<"$FSCK_OUT")"

# ------------------------------------------------------------- gate 4b
# With the scrub armed, deleted-file residue (allocated nlink=0 inodes)
# must be GONE by the final fsck: the quiet window gave it >= 2 full
# cycles after the last delete. If orphans survive, the scrub stopped
# reclaiming them -- the exact job gate 4 once misattributed to a leak.
# With the scrub off, residue is legal and merely counted.
ORPHANS="$(grep -c "is allocated but has nlink=0" <<<"$FSCK_OUT" || true)"
if [ "$SCRUB" = 0 ]; then
    log "deleted-file residue left with the scrub off: $ORPHANS orphan inode(s) (legal; the scrub's to reclaim)"
else
    [ "$ORPHANS" = 0 ] &&
        pass "no deleted-file residue survived the scrub (orphan inodes all reclaimed)" ||
        { fail "$ORPHANS orphan inode(s) survived >=2 quiet scrub cycles -- the scrub is not reclaiming residue"; keep_evidence; }
fi
LEAKED="$(sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode (leaked)/\1/p' <<<"$FSCK_OUT" | head -1)"
[ -n "$LEAKED" ] || LEAKED=0
[ "$LEAKED" = 0 ] &&
    pass "fsck finds no leaked data blocks after the churn" ||
    { fail "fsck finds $LEAKED data block(s) marked in use but referenced by no inode -- the churn leaked them"; keep_evidence; }

# --------------------------------------------------------------- gate 6
# The shadow bitmap is an in-core record of every data-block alloc and
# free, kept under alloc_mutex and therefore immune to anything the
# buffer cache does. It is the only detector here that can name a double
# allocation at the moment it happens rather than by its consequences.
# Both halves matter, and the second one is what a scrub freeing live
# blocks looks like from the owner's side: the owner's eventual free
# lands on a block that is already free. Grepping only for DOUBLE-ALLOC
# would have stayed silent through exactly that.
# Only the pre-remount window: see SHADOW_MARK above for why a free
# after a remount cannot be judged by an in-core shadow.
SHADOW_WINDOW="$(dmesg_since "$CT_DMESG_MARK" | sed -n "1,/$SHADOW_MARK/p")"
[ -n "$SHADOW_WINDOW" ] || SHADOW_WINDOW="$(dmesg_since "$CT_DMESG_MARK")"
if grep -qE "SHADOW DOUBLE-ALLOC|SHADOW FREE-OF-UNTRACKED|already free \(double free" <<<"$SHADOW_WINDOW"; then
    fail "the allocator detectors caught a double allocation or a double free"
    grep -m4 -E "SHADOW|already free" <<<"$SHADOW_WINDOW" | cut -c1-160
    keep_evidence
else
    pass "no double allocation or double free reported by the allocator detectors"
fi
# A double free is still a fault after the remount; the BITMAP can say so
# without the shadow, because it is on-disk truth rather than in-core.
if dmesg_since "$CT_DMESG_MARK" | grep -qE "already free \(double free"; then
    fail "a block was freed twice (the on-disk bitmap said it was already free)"
else
    pass "no block was freed twice"
fi
if dmesg_since "$CT_DMESG_MARK" | grep -qE "below zero|could not be applied"; then
    fail "a free-count delta could not be applied -- the counters have drifted from the bitmaps"
    dmesg_since "$CT_DMESG_MARK" | grep -m4 -E "below zero|could not be applied"
else
    pass "no free-count drift reported during the churn"
fi

rm -rf "$STATE"
ct_exit
