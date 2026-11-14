#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the per-block bitmap gate reads a count, not every Block Group chunk
#
# Before a mapped block's extent is published at tree depth >= 1, the
# gate flushes allocation bits still only in memory (rule 8). It asked
# "is anything dirty?" by walking the dirty mark of every Block Group
# chunk, once per mapped block: ~0.5 ms of CPU per call at 64 TiB (audit
# 2026-11-14 P7). It now reads a count of the marks, raised before a mark
# is set and lowered after one is cleared, so it is never below them.
#
# The same workload -- a file written every other block, so each block
# is its own extent and the tree goes deep -- runs with the count and with the walk (bmap_gate_walk):
#   1. the gate is reached on every mapped block (the walk's count);
#   2. with the count it walks nothing;
#   3. and enters to flush exactly as often as the walk did: a count that
#      read 0 over a set mark would enter less, and publish extents
#      ahead of their bits.
#
# DISCRIMINATION for 3: measured with the count's raise removed from
# cetrafs_sb_note_bmap_alloc(), the count run entered 0 times.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bmap_gate_walk ] || { skip "bmap_gate_walk is missing"; ct_exit; }
MNT="$(ct_mnt bgcost)"
ct_track mnt "$MNT"
ct_param_set bmap_gate_walk 0
P=/sys/module/cetrafs/parameters

# <walk 0|1> -> "<walks> <entries>"
probe() {
    local dev info w0 e0 w1 e1
    dev="$(ct_dev 560 "bgcost$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    info="/proc/fs/cetrafs/$(basename "$dev")/info"
    echo "$1" >$P/bmap_gate_walk
    w0="$(awk '$1 == "bmap_gate_walks:" { print $2 }' "$info")"
    e0="$(awk '$1 == "bmap_gate_entries:" { print $2 }' "$info")"
    python3 - "$MNT" <<'PY'
import os, sys
fa = os.open(sys.argv[1] + "/a", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(240):
    os.pwrite(fa, b"\x33" * 4096, i * 8192)  # every other block: each one its own extent
os.fsync(fa)  # one boundary: writeback maps the blocks, each mapping passes the gate
os.close(fa)
PY
    w1="$(awk '$1 == "bmap_gate_walks:" { print $2 }' "$info")"
    e1="$(awk '$1 == "bmap_gate_entries:" { print $2 }' "$info")"
    echo 0 >$P/bmap_gate_walk
    ct_umount "$MNT"
    echo "$((w1 - w0)) $((e1 - e0))"
}

read -r W1 E1 <<<"$(probe 1)"
read -r W0 E0 <<<"$(probe 0)"
log "walk: $W1 walks, $E1 entries; count: $W0 walks, $E0 entries"
[ "$W1" -ge 100 ] && pass "1: the gate was reached $W1 times by 240 appended blocks" ||
    { fail "setup: the gate was reached $W1 times -- the files did not go deep enough"; ct_exit; }
[ "$W0" = 0 ] && pass "2: with the count the gate walked no chunk" || fail "2: the gate walked $W0 times"
[ "$E0" = "$E1" ] && [ "$E0" -gt 0 ] && pass "3: it entered to flush $E0 times, as the walk did" ||
    fail "3: entered $E0 times with the count, $E1 with the walk"
ct_exit
