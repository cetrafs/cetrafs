#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the last-writer close publishes size and extents BEFORE it releases the file lock
#
# A peer may open a file the instant its on-disk lock reads NONE, and
# refreshes from the record it finds there. The last-writer close used to
# clear the lock first and publish the file sector -- size, blocks, the
# extent shadow -- only afterwards, so in between the device said "free"
# about a record missing this node's last writes: the peer opened a short
# file, and the two publishes then landed over each other. lock.c's own
# comment claimed the opposite ("a peer can never see the lock released
# with the new size not yet durable"), from a time the two were one CAS.
#
# release_step_gap_ms holds the close between its two steps; the test
# samples the record on the device (the backing file: what a peer would
# read) during the gap. The invariant: whenever the lock reads NONE, the
# size is already the final one.
#
# DISCRIMINATION (measured on the unfixed order): samples show the lock
# NONE with size 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LPOKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_dev 560 clspub)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt clspub)"
SAMPLES="$(ct_tmp clspub-samples)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

touch "$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
SIZE=$((1024 * 1024))

ct_param_set release_step_gap_ms 1500

READY="$(ct_tmp clspub-ready)"
rm -f "$READY"

# Writer: open, write, signal, close -- the close sits in the gap 1.5 s.
# The signal comes after the write, so the lock is ours by then: before
# the open, "free with size 0" is a legitimate state, not the bug.
python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.write(fd, b'x' * int(sys.argv[2]))
open(sys.argv[3], 'w').close()
os.close(fd)" "$MNT/f" "$SIZE" "$READY" &
WPID=$!
for _ in $(seq 1 100); do [ -e "$READY" ] && break; sleep 0.05; done

# Sampler: what a peer would read off the device, until the close returns.
: >"$SAMPLES"
while kill -0 "$WPID" 2>/dev/null; do
    mode="$("$LPOKE" "$BACK" "$INO" | sed -n 's/.* mode=\([0-9]*\) .*/\1/p')"
    size="$("$LPOKE" "$BACK" "$INO" --rec | sed -n 's/^size=\([0-9]*\) .*/\1/p')"
    echo "$mode $size" >>"$SAMPLES"
    sleep 0.05
done
wait "$WPID"
mode="$("$LPOKE" "$BACK" "$INO" | sed -n 's/.* mode=\([0-9]*\) .*/\1/p')"
size="$("$LPOKE" "$BACK" "$INO" --rec | sed -n 's/^size=\([0-9]*\) .*/\1/p')"
echo "$mode $size" >>"$SAMPLES"

n_total=$(wc -l <"$SAMPLES")
n_held=$(awk '$1 == 1' "$SAMPLES" | wc -l)
n_free=$(awk '$1 == 0' "$SAMPLES" | wc -l)
bad=$(awk -v s="$SIZE" '$1 == 0 && $2 != s' "$SAMPLES" | sort | uniq -c | head -3 | tr '\n' ';')
log "$n_total samples: $n_held with the lock held, $n_free with it free"

# Setup proof: the sampler saw the close in progress, and saw it finish.
if [ "$n_total" -ge 10 ]; then
    pass "sampled the device $n_total times across the close"
else
    fail "only $n_total samples -- the gap did not hold the close (is release_step_gap_ms honoured?)"
fi
if [ "$(tail -1 "$SAMPLES")" = "0 $SIZE" ]; then
    pass "after the close the lock is free and the size is $SIZE"
else
    fail "after the close the record reads '$(tail -1 "$SAMPLES")', expected '0 $SIZE'"
fi

if [ -z "$bad" ]; then
    pass "whenever the lock read free on the device, the size was already final"
else
    fail "the lock read FREE while the record still had a stale size (count mode size): $bad"
fi

ct_exit
