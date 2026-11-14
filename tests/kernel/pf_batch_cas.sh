#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# One pending-free swap carries several extents, not one.
#
# A free aimed at another node's Zone Group is appended to that ZG's
# queue, and each compare-and-swap placed exactly ONE extent. Deleting a
# file of tens of thousands of extents from a node that does not own its
# groups was therefore one device round trip per extent, which on a real
# array is about forty minutes of rm.
#
# The queue region one swap covers holds several entries (16 on a 512 B
# logical block), so one swap now places every free slot it can, and an
# evict or truncate batches its extents into those swaps. The loop device
# has no CAW, so the append side runs here only under pf_force_foreign
# (a test-only knob that routes every free through the queue); the
# two-node run measures it for real.
#
# The counters: pending_free_appends counts swaps that placed entries,
# pending_free_entries counts the extents they carried.
#
#   setup:       the delete must have queued the extents this suite
#                assumes (one per extent), or nothing below means anything
#   batched:     swaps must be a small fraction of the extents
#   control:     pf_batch_size=1 restores one swap per extent
#   queue full:  a full queue drops every extent it cannot place, counts
#                them, and the delete still succeeds for the caller
#   recovery:    after a remount every queued extent is applied: free
#                space is back and fsck is clean
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
suite "foreign frees batch several extents per queue swap"

FILES=300

IMG="$(ct_image 1200 pfbatch)"
LOOP="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfbatch)"
INFO="/proc/fs/cetrafs/$(basename "$LOOP")/info"
ct_mkfs "$LOOP" -f >/dev/null
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"

counter() { awk -v k="^$1:" '$0 ~ k {print $2}' "$INFO"; }

ct_param_set pf_force_foreign 1
ct_param_set pf_full_backoff_ms 0
FREE0="$(stat -f -c '%f' "$MNT")"

# FILES extents in one file, each its own extent (a 2-block stride leaves
# a hole between them), so the delete queues FILES entries whatever the
# allocator does.
# Prints "<extents> <swaps> <drops>" for the delete alone.
burst() { # <name>
    local name="$1" a0 a1 e0 e1 d0 d1 i f
    # ONE file of FILES extents, not FILES one-block files: a batch spans
    # the extents of one operation, and each small file's unlink is its own.
    # Stride 2 blocks, so no two extents are contiguous.
    f="$MNT/$name"
    for i in $(seq 0 $((FILES - 1))); do
        dd if=/dev/zero of="$f" bs=4k count=1 seek=$((2 * i)) conv=notrunc status=none
    done
    sync
    # Let any backoff left by setup expire, so the first drop of this
    # burst is not swallowed by it.
    sleep 1.5
    a0="$(counter pending_free_appends)"
    e0="$(counter pending_free_entries)"
    d0="$(counter pf_drop_runs)"
    rm -f "$f"
    # Blocks are freed at EVICTION: without this the delete frees nothing.
    sync; echo 3 >/proc/sys/vm/drop_caches; sync
    a1="$(counter pending_free_appends)"
    e1="$(counter pending_free_entries)"
    d1="$(counter pf_drop_runs)"
    echo "$((e1 - e0)) $((a1 - a0)) $((d1 - d0))"
}

# ---- setup and batched ----------------------------------------------
read -r EXT SWAPS DROPS <<<"$(burst batched)"
log "batched:  $EXT extent(s) in $SWAPS swap(s), $DROPS dropped"

if [ "$EXT" -lt $((FILES * 9 / 10)) ]; then
    fail "setup: the delete queued $EXT extent(s) for a $FILES-extent file -- the suite's premise does not hold"
else
    pass "setup: the delete queued $EXT extent(s), one per extent of the file"
fi

if [ "$SWAPS" -ge 1 ] && [ "$((SWAPS * 8))" -le "$EXT" ]; then
    pass "batched: $EXT extents took $SWAPS queue swap(s) -- several per swap"
else
    fail "batched: $EXT extents took $SWAPS queue swap(s) -- one swap per extent, or nothing queued"
fi

# ---- control: one extent per swap -----------------------------------
ct_param_set pf_batch_size 1
read -r CEXT CSWAPS CDROPS <<<"$(burst control)"
log "control:  $CEXT extent(s) in $CSWAPS swap(s)"
if [ "$CSWAPS" -ge $((CEXT * 9 / 10)) ] && [ "$CSWAPS" -le "$CEXT" ]; then
    pass "control: pf_batch_size=1 restores one swap per extent ($CSWAPS for $CEXT)"
else
    fail "control: pf_batch_size=1 gave $CSWAPS swap(s) for $CEXT extent(s) -- the knob does not isolate the batching"
fi
ct_param_set pf_batch_size 0

# ---- recovery -------------------------------------------------------
# The batched and control extents are ours (pf_force_foreign), so a
# remount applies them: free space must come back to the baseline taken
# before the first burst, and fsck must be clean. Done BEFORE the queue
# full burst, whose deliberate leaks would make fsck report leaked blocks.
ct_param_set pf_force_foreign 0
ct_umount "$MNT"
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"
FREE_NOW="$(stat -f -c '%f' "$MNT")"
ct_umount "$MNT"
if [ "$FREE_NOW" = "$FREE0" ]; then
    pass "recovery: free space is back to the baseline after the remount applied the queue"
else
    fail "recovery: $FREE_NOW free blocks after the remount, baseline was $FREE0 -- queued frees were lost or double-applied"
fi
if ct_fsck "$LOOP" >/dev/null 2>&1; then
    pass "recovery: fsck clean after the batched frees were applied"
else
    fail "recovery: fsck failed after the batched frees were applied"
fi

# ---- queue full -----------------------------------------------------
# Every extent is dropped, counted, and the caller's delete succeeds.
ct_mount "$LOOP" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set pf_force_foreign 1
ct_param_set pf_force_queue_full 1
L0="$(counter foreign_free_leaks)"
read -r FEXT FSWAPS FDROPS <<<"$(burst full)"
L1="$(counter foreign_free_leaks)"
ct_param_set pf_force_queue_full 0
log "queue full: $FEXT extent(s) seen, $FDROPS dropped, $((L1 - L0)) leak(s) counted"
if [ "$FDROPS" -ge "$((FEXT * 9 / 10))" ] && [ "$((L1 - L0))" -ge "$FDROPS" ] && [ "$FSWAPS" -eq 0 ]; then
    pass "queue full: $FDROPS extent(s) dropped and counted, none placed, the delete succeeded"
else
    fail "queue full: $FDROPS dropped, $((L1 - L0)) leak(s) counted, $FSWAPS swap(s) -- a full queue must drop and count every extent"
fi
ct_param_set pf_force_foreign 0
ct_umount "$MNT"

ct_exit
