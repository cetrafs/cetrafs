#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# random writes into holes: the janitor heals the fragmentation (audit P11)
#
# A file filled in random order lands one extent per block: an append
# merges only with the LAST array entry, and a hole's block never meets
# its logical neighbour, so 64 MiB of 4 KiB writes in random order is
# 16,384 extents, where sequential order is one. The leaf rule (arrays
# are append-only and unordered) stays; the online defragmenter is what
# heals it. Its close trigger already fired on such a file, but the mover
# read the unsorted array as the logical map, judged it full of interior
# holes and declined, forever. It now sorts the list first.
#
# Asserted: after the random fill and a bounded wait, with auto_defrag on,
# the extent count falls by an order of magnitude and the data reads back
# byte-for-byte. The control (defrag_extents_unsorted=1, the old read)
# must leave the file near 16k extents for the same wait. fsck clean.
set -euo pipefail
trap 'echo "ABORT at line $LINENO: $BASH_COMMAND (rc=$?)" >&2' ERR
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "filefrag is missing"; ct_exit; }

BLOCKS=16384                      # 64 MiB at 4 KiB
IMG="$(ct_image 1024 rndholes)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rndholes)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set auto_defrag 1 # the harness turns it off for every suite
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# extents <file>: the extent count, one line per extent
# (-v: the summary line undercounts a file this fragmented)
extents() { filefrag -v "$1" | grep -cE '^ *[0-9]+:'; }

# fill <file>: every block of a 64 MiB file, written once, in a random
# order, through one open -- the pattern the janitor has to heal.
fill() {
    python3 - "$1" "$BLOCKS" <<'PY'
import os, sys, random
path, n = sys.argv[1], int(sys.argv[2])
order = list(range(n))
random.seed(7)
random.shuffle(order)
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    for i, b in enumerate(order):
        blk = (b.to_bytes(4, "little") * 1024)[:4096]   # block b's own pattern
        os.pwrite(fd, blk, b * 4096)
finally:
    os.close(fd)
PY
}

# verify <file>: every block holds its own pattern (byte-for-byte)
verify() {
    python3 - "$1" "$BLOCKS" <<'PY'
import os, sys
path, n = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDONLY)
bad = 0
try:
    for b in range(n):
        want = (b.to_bytes(4, "little") * 1024)[:4096]
        if os.pread(fd, 4096, b * 4096) != want:
            bad += 1
finally:
    os.close(fd)
print("BAD=%d" % bad)
PY
}

# ---------------------------------------------------- the trigger, the fix
log "random 4 KiB writes into holes, then a bounded wait for the janitor"
ct_param_set defrag_extents_unsorted 0
fill "$MNT/rnd"
E0="$(extents "$MNT/rnd")"
# Setup: the fill really fragmented the file, or nothing below is measured.
[ "$E0" -ge $((BLOCKS / 2)) ] ||
    { fail "setup: the random fill left only $E0 extents -- nothing to heal"; ct_exit; }
pass "setup: the random fill left $E0 extents (sequential order would be 1)"

# The janitor works in the background: poll a bounded time.
E1="$E0"
for _ in $(seq 1 60); do
    sleep 1
    E1="$(extents "$MNT/rnd")"
    [ "$E1" -le $((E0 / 10)) ] && break
done
[ "$E1" -le $((E0 / 10)) ] &&
    pass "auto_defrag heals the random fill: $E0 -> $E1 extents (an order of magnitude)" ||
    fail "auto_defrag left $E1 extents from $E0 after 60 s (wanted at most $((E0 / 10)))"
[ "$(verify "$MNT/rnd")" = "BAD=0" ] &&
    pass "every block reads back its own bytes after the healing" ||
    fail "data changed under the defragmenter: $(verify "$MNT/rnd")"

# ----------------------------------------------------- the control: old trigger
log "control: the old unsorted read leaves the fill fragmented"
ct_param_set defrag_extents_unsorted 1
fill "$MNT/rnd-old"
EC0="$(extents "$MNT/rnd-old")"
[ "$EC0" -ge $((BLOCKS / 2)) ] || { fail "control setup: the fill left only $EC0 extents"; ct_exit; }
sleep 30
EC="$(extents "$MNT/rnd-old")"
[ "$EC" -ge $((BLOCKS / 2)) ] &&
    pass "control: with the unsorted read the fill stays at $EC extents after 30 s" ||
    fail "control: with the unsorted read the fill went to $EC extents -- the sort is not what healed it"
ct_param_set defrag_extents_unsorted 0

ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean after the random fills and the healing" ||
    fail "fsck: $(grep -m3 -i 'err\|bad\|leak' <<<"$out" | tr '\n' ' ')"
ct_exit
