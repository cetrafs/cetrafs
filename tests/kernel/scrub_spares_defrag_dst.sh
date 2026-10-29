#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub never reclaims a defrag's destination run while the move is live
#
# cetrafs_defrag_file() allocates the whole destination run up front and
# publishes it one committed step at a time. Until a step commits, those
# blocks are bitmap-allocated and referenced by nothing -- for the whole
# move, which on a badly fragmented file is seconds, not the single
# get_block() the scrub's leak argument assumes.
#
# scrub.c's header states the rule outright: "anything that leaves a
# block bitmap-allocated for longer than one get_block() without
# committing an extent MUST appear there [on the live-reservation
# registry]". lock.c's speculative run was the ONLY thing that ever
# registered. The defrag destination did not, so the background scrub
# reclaimed a move in progress, the allocator handed those blocks out
# again, and the defrag committed them anyway -- two files, one block.
#
# Discrimination: defrag_skip_resv=1 leaves the run unregistered, the
# way it was. With it the scrub MUST reclaim part of the destination.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PROBE="$(ct_helper defrag_dst_probe)"
# The move must outlive a scrub cycle or neither arm measures anything;
# 8192 blocks finished in under one. The copy is a synchronous
# block-at-a-time write, so this scales with the count.
BLOCKS="${CT_DEFRAG_DST_BLOCKS:-49152}" # 192 MiB, scattered one block at a time
OUT="$(ct_tmp defragdst-out)"
DEV="$(ct_big_dev 6144 defragdst)"
MNT="$(ct_mnt defragdst)"

ct_mkfs_small "$DEV" >/dev/null
# The fastest cycle the scrub allows, so one lands inside the move
# rather than the move having to be long enough to catch a slow one.
ct_param_set scrub_interval_secs 1
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
echo "defrag on" >"$PROC/controls"
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }
cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }

# <label> <expect-reclaim: no|yes>
run_move() {
    local label="$1" expect="$2" r0 c0 got cyc

    "$PROBE" "$MNT" "$BLOCKS" build | sed 's/^/    /'
    r0="$(reclaimed)"
    c0="$(cycles)"
    # Isolate the registration. Allocating the destination run itself
    # moves the Block Group's allocation count, and the scrub abandons a
    # group that moved (cetrafs_sb_info.bg_alloc_seq) -- which would
    # spare the destination in BOTH arms and prove nothing about the
    # reservation. Stand that gate down so the registration is the only
    # difference between them.
    ct_param_set scrub_ignore_alloc_seq 1
    ct_param_set scrub 1
    # Begin just after a cycle completes, so the NEXT one starts while
    # the move is still running instead of landing wherever the timer
    # happened to be.
    local cwait="$(cycles)"
    wait_for 20 '[ "$(sed -n "s/^scrub_cycles: //p" "'"$PROC"'/info")" -gt '"$cwait"' ]' || true
    "$PROBE" "$MNT" "$BLOCKS" defrag >"$OUT" 2>&1 &
    local pid=$!
    wait "$pid" || true
    cyc=$(($(cycles) - c0))
    got=$(($(reclaimed) - r0))
    ct_param_set scrub 0
    ct_param_set scrub_ignore_alloc_seq 0
    sed 's/^/    /' "$OUT"
    log "$label: the move overlapped $cyc scrub cycle(s); reclaimed $got block(s)"

    # A move that outran the scrub proves nothing either way. How long
    # the move takes depends on machine load, so the size self-tunes
    # rather than being a constant that is right on an idle box and
    # wrong inside a full `make check` -- where this suite reported
    # exactly that and refused to draw a conclusion.
    #
    # The reclaim arm needs TWO full cycles inside the move, not one: the
    # counter ticks at the END of pass1+gap+pass2, so a single overlapped
    # cycle can be one whose pass 1 ran before the destination existed
    # (or when the mover had already committed most steps), and pass 2
    # then correctly confirms nothing -- "reclaimed 0" without proving
    # anything about the registration. With two, the second cycle's
    # pass 1 is guaranteed to start mid-move. A fast box hit exactly the
    # one-cycle edge and failed the discrimination arm on a correct
    # kernel (2026-10-29).
    local need=1
    [ "$expect" = "yes" ] && need=2
    if [ "$cyc" -lt "$need" ]; then
        # Bounded: the victim AND its interleaved spacer are written,
        # and the move then needs a destination run as big again, so
        # this must stay well inside the device.
        if [ "$BLOCKS" -lt 150000 ]; then
            BLOCKS=$((BLOCKS * 2))
            log "$label: only $cyc cycle(s) inside the move (need $need) -- retrying with $BLOCKS blocks"
            run_move "$label" "$expect"
            return
        fi
        if [ "$expect" = "yes" ]; then
            # The reclaim arm is timing-bound: on a box whose pass-2
            # refset build is slower than the whole move, growing the
            # move grows the scan too and two full cycles NEVER fit.
            # That is inconclusive, not a defect -- the arm still runs
            # (and discriminates) on boxes where the cycles fit.
            skip "$label: two scrub cycles never fit inside the move on this box (even at $BLOCKS blocks) -- inconclusive here"
            return
        fi
        fail "$label: the defrag outran the scrub even at $BLOCKS blocks ($cyc cycle(s), need $need)"
    fi

    if [ "$expect" = "no" ]; then
        [ "$got" = 0 ] &&
            pass "the scrub reclaimed nothing while a defrag held its destination run" ||
            fail "the scrub reclaimed $got block(s) during a live defrag -- the allocator can hand them out mid-move"
    else
        [ "$got" -gt 0 ] &&
            pass "unregistered, the scrub reclaimed $got block(s) of the live destination -- the registration is what prevents it" ||
            fail "even unregistered nothing was reclaimed -- the registration is not what protects the move, something else is"
    fi
    "$PROBE" "$MNT" "$BLOCKS" verify >"$OUT" 2>&1 || true
    sed 's/^/    /' "$OUT"
}

log "defragging a badly fragmented file while the scrub runs"
run_move "with the destination registered" no
grep -q "^content: ok" "$OUT" && pass "the defragged file is byte-exact" ||
    fail "the defragged file is damaged: $(grep -m1 '^content:' "$OUT")"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck reports a problem: $(ct_fsck "$DEV" 2>&1 | grep -m1 -iE 'ERR|overlap|leaked')"

# ------------------------- is the registration what protects the move?
if [ -w /sys/module/cetrafs/parameters/defrag_skip_resv ]; then
    log "discrimination: the same move with the destination left unregistered"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo "defrag on" >"$PROC/controls"
    ct_param_set defrag_skip_resv 1
    run_move "with the destination unregistered" yes
    ct_param_set defrag_skip_resv 0
    ct_umount "$MNT"
else
    skip "defrag_skip_resv unavailable -- cannot measure what the registration contributes"
fi

ct_exit
