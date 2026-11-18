#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rebuilt extent tree leaves room in its leaves for the next converts
#
# cetrafs_tree_build() packed every leaf of a depth-2 tree full. A
# convert splits a preallocated extent around the block written; in a
# full leaf there is no room for the pieces, so one goes to the tree's
# last leaf -- and after every punch, truncate or fallocate (each rebuilds
# the whole tree) the next scatter of first writes paid that per write
# (audit 2026-11-15 G-3). Rebuilt leaves are now three-quarters full.
#
# A preallocated file whose tree reaches depth 2 (every 4th block of its
# first 4,000 written), rebuilt by a punch of one written block; then
# 120 first writes into preallocated blocks spread over the rebuilt
# leaves.
#   setup: with full leaves (the control) most converts spill -- the
#      writes land in rebuilt leaves;
#   1. the 120 converts stay in their own leaves: convert_spills moves
#      by under a tenth of them.
#
# DISCRIMINATION: tree_build_full=1 (full leaves): most of the converts
# spill.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/tree_build_full ] || { skip "tree_build_full is missing"; ct_exit; }
MNT="$(ct_mnt rbls)"
ct_track mnt "$MNT"
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set tree_build_full 0
# The punch below rebuilds the whole tree only with patching off: since
# 60335f9 a punch copies just the leaves it touches. A full rebuild is
# still what a patch that cannot apply, fallocate's allocation and the
# defrag mover do, and what this suite measures.
ct_param_set tree_patch_off 1

# <full 0|1> -> "depth=<n> spills=<n> splits=<n>"
round() {
    local dev proc s0 s1 p0 p1
    dev="$(ct_dev 900 "rbls$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "$1" >/sys/module/cetrafs/parameters/tree_build_full
    fallocate -l $((8192 * 4096)) "$MNT/f"
    python3 -I - "$MNT/f" w <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096); m.write(b"x" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
for b in range(0, 4000, 4):
    os.pwrite(fd, m, b * 4096)
os.close(fd)
PY
    # the punch of one written block rebuilds the whole tree
    fallocate -p -o $((8 * 4096)) -l 4096 "$MNT/f"
    sync
    s0="$(sed -n 's/^convert_spills: //p' "$proc/info")"
    p0="$(sed -n 's/^leaf_splits: //p' "$proc/info")"
    python3 -I - "$MNT/f" <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096); m.write(b"y" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
for k in range(120):
    os.pwrite(fd, m, (2 + 32 * k) * 4096)   # a preallocated block between written ones
os.close(fd)
PY
    s1="$(sed -n 's/^convert_spills: //p' "$proc/info")"
    p1="$(sed -n 's/^leaf_splits: //p' "$proc/info")"
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/tree_build_full
    echo "spills=$((s1 - s0)) splits=$((p1 - p0))"
}
get() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "slack: $R"
C="$(round 1)"
log "control (full leaves): $C"
[ "$(get spills "$C")" -ge 60 ] || { fail "setup: with full leaves only $(get spills "$C") of 120 converts spilled -- the converts did not land in rebuilt full leaves ($C)"; ct_exit; }
pass "setup: with full leaves $(get spills "$C") of 120 converts spilled out of their leaf"
[ "$(get spills "$R")" -lt 12 ] && pass "1: with the rebuild's slack $(get spills "$R") of 120 spilled" ||
    fail "1: with slack, $(get spills "$R") of 120 converts still spilled ($R)"
ct_exit
