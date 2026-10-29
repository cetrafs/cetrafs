#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub never reclaims blocks a live file has written but not published
#
# The hot write path stages extent state in cetrafs_inode_info.fd_shadow
# and publishes it to the device only at a durability boundary. Until
# then the file's blocks are bitmap-allocated and named by NOTHING on
# the platter.
#
# scrub.c's own safety argument (its header, point 2) is that "a real
# allocation commits its extent within one get_block() -- milliseconds",
# which the two-pass gap then dwarfs. That was true before the shadow
# existed. With it, one large write holds tens of thousands of blocks
# unpublished for as long as the writer goes without syncing, and the
# deciding pass -- the one whose verdict FREES -- read the on-disk
# record alone. cetrafs_inode_fd_overlay() says "every file-path read of
# extent state goes through this"; this read did not.
#
# What that cost, from a churn run: the scrub freed a live file's
# blocks, the allocator handed them to another file, and fsck reported
#   "block 99859 is referenced by more than one inode -- cross-file overlap"
#   "free: block 90533 was already free (double free of extent [90528 +26721))"
#
# Discrimination: scrub_ignore_shadow=1 removes the overlay and nothing
# else. With it the scrub MUST reclaim blocks from this live file --
# otherwise the overlay is not what protects them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PROBE="$(ct_helper scrub_shadow_probe)"
BLOCKS=20000 # ~78 MiB: big enough that the shadow cannot be published in passing
HOLD=25      # the write, then comfortably more than two cycles of the fast scrub

OUT="$(ct_tmp scrubshadow-out)"
DEV="$(ct_dev 900 scrubshadow)"
MNT="$(ct_mnt scrubshadow)"
ct_mkfs_small "$DEV" >/dev/null

ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }
cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }

# <label> <expect-reclaim: no|yes>
run_probe() {
    local label="$1" expect="$2" r0 c0 got out rc

    # Isolate the overlay. Writing the file allocates, which moves the
    # Block Group's allocation count, and the scrub then abandons the
    # whole group (cetrafs_sb_info.bg_alloc_seq) -- so with that gate
    # live NOTHING is reclaimed either way and this suite would measure
    # the wrong protection. Stand it down for both arms, leaving the
    # overlay as the only thing that can differ between them.
    ct_param_set scrub_ignore_alloc_seq 1

    # Arm the scrub only once the data is DOWN and the shadow is dirty.
    # Started earlier, a cycle can fall entirely before the write and
    # find nothing to propose -- the measurement then depends on where
    # the scrub's timer happened to land, which is how the first version
    # of this suite reported "reclaimed 0" in both arms and proved
    # nothing. The probe's "written:" line is the signal.
    : >"$OUT"
    "$PROBE" "$MNT/live" "$BLOCKS" "$HOLD" >"$OUT" 2>&1 &
    local pid=$!
    wait_for 60 'grep -q "^written:" "'"$OUT"'"' ||
        fail "$label: the probe never finished writing"
    r0="$(reclaimed)"
    c0="$(cycles)"
    ct_param_set scrub 1
    # Let the scrub get at least two full cycles in while the file sits
    # written-but-unpublished; otherwise a clean result means only that
    # the scrub never looked.
    wait_for 40 '[ "$(( $(sed -n "s/^scrub_cycles: //p" "'"$PROC"'/info") - '"$c0"' ))" -ge 2 ]' ||
        log "note: fewer than two cycles elapsed"
    got=$(($(reclaimed) - r0))
    wait "$pid" && rc=0 || rc=$?
    ct_param_set scrub 0
    ct_param_set scrub_ignore_alloc_seq 0
    out="$(cat "$OUT")"
    echo "$out" | sed 's/^/    /'
    log "$label: scrub reclaimed $got block(s) across $(($(cycles) - c0)) cycle(s)"

    [ "$(($(cycles) - c0))" -ge 2 ] ||
        fail "$label: the scrub ran fewer than two cycles -- this measures nothing"

    if [ "$expect" = "no" ]; then
        [ "$got" = 0 ] &&
            pass "the scrub reclaimed nothing from a file whose extents are only in the shadow" ||
            fail "the scrub reclaimed $got block(s) of a live file -- they are the allocator's to hand out now"
        grep -q "^content: ok" <<<"$out" && [ "$rc" = 0 ] &&
            pass "the file is byte-exact after the scrub" ||
            fail "the live file lost data: $(grep -m1 '^content:' <<<"$out")"
    else
        [ "$got" -gt 0 ] &&
            pass "without the overlay the scrub reclaimed $got block(s) of the live file -- the overlay is what prevents it" ||
            fail "even without the overlay nothing was reclaimed -- the overlay is not what protects a live file's blocks, something else is"
    fi
}

log "a large write held open, unpublished, across two scrub cycles"
run_probe "with the shadow overlay" no

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck reports a problem: $(ct_fsck "$DEV" 2>&1 | grep -m1 -iE 'ERR|overlap|leaked')"

# ------------------------------- is the overlay what protects the blocks?
if [ -w /sys/module/cetrafs/parameters/scrub_ignore_shadow ]; then
    log "discrimination: the same file with the scrub deciding from the device alone"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set scrub_ignore_shadow 1
    run_probe "without the shadow overlay" yes
    ct_param_set scrub_ignore_shadow 0
    ct_umount "$MNT"
else
    skip "scrub_ignore_shadow unavailable -- cannot measure what the overlay contributes"
fi

ct_exit
