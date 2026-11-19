#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rebuild frees the old tree only once no writeback walk of it is in flight
#
# Writeback maps through the extent tree holding no invalidate_lock (it
# cannot: truncate waits for writeback holding it), so a truncate's free
# of the old tree's blocks could land under a walk that read the old
# root before the publish, and the block be reused under it (audit
# 2026-11-15 BC-9). The walks are now counted and the free waits.
#
# Ordinary I/O never makes writeback walk the tree (every folio's
# buffers are mapped before it is dirty; wb_tree_walks stays 0 under a
# mixed workload), so a hook makes one: the next writeback pass looks
# block 0 up (wb_walk_force) and stalls 3 s first (wb_walk_stall_ms).
# Staged: a file whose map spilled into a leaf; a writeback pass in that
# stall; a truncate that rebuilds the map to depth 0 and frees the leaf.
#   setup: the walk ran (wb_tree_walks moved) and the truncate rebuilt;
#   1. the truncate returned only after the walk ended.
#
# DISCRIMINATION: wb_walk_undrained=1 -- the truncate returns while the
# walk is still stalled.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in wb_walk_force wb_walk_stall_ms wb_walk_undrained; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt wbwd)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set wb_walk_force 0
ct_param_set wb_walk_stall_ms 0
ct_param_set wb_walk_undrained 0

# <undrained 0|1> -> "depth= walked= after_ms="
round() {
    local img dev f ino proc w0 depth pid t0 t1 walked=0 after
    img="$(ct_image 560 "wbwd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    f="$MNT/f"
    for i in $(seq 0 2 40); do
        dd if=/dev/urandom of="$f" bs=4096 count=1 seek="$i" conv=notrunc,fsync status=none
    done
    ino="$(stat -c %i "$f")"
    sync
    depth="$("$IPOKE" "$img" extents "$ino" | sed -n 's/.*depth=\([0-9]*\).*/\1/p' | head -1)"
    echo "$1" >/sys/module/cetrafs/parameters/wb_walk_undrained
    w0="$(sed -n 's/^wb_tree_walks: //p' "$proc/info")"
    # Dirty on an fd that stays open (a close writes everything back,
    # leaving the fsync nothing to pass over), then the fsync's pass.
    python3 -I - "$f" <<'PY' &
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, b"D" * 4096, 0)
open("/sys/module/cetrafs/parameters/wb_walk_stall_ms", "w").write("3000")
open("/sys/module/cetrafs/parameters/wb_walk_force", "w").write("1")
os.fsync(fd)
os.close(fd)
PY
    pid=$!
    t0=$(date +%s%N)
    sleep 0.5 # the pass is in its walk's stall
    truncate -s 4096 "$f"
    t1=$(date +%s%N)
    wait "$pid" || true
    [ "$(sed -n 's/^wb_tree_walks: //p' "$proc/info")" -gt "$w0" ] && walked=1
    after=$(((t1 - t0) / 1000000))
    echo 0 >/sys/module/cetrafs/parameters/wb_walk_undrained
    ct_umount "$MNT"
    echo "depth=${depth:-0} walked=$walked after_ms=$after"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "drained: $R"
C="$(round 1)"
log "control (undrained): $C"
for v in "$R" "$C"; do
    [ "$(get depth "$v")" -ge 1 ] && [ "$(get walked "$v")" = 1 ] ||
        { fail "setup: no leaf, or writeback never walked ($v)"; ct_exit; }
done
pass "setup: a writeback walk stalled while a truncate rebuilt a spilled map"
[ "$(get after_ms "$R")" -ge 2800 ] && pass "1: the truncate returned only after the walk ended ($(get after_ms "$R") ms)" ||
    fail "1: the truncate returned while the walk was in flight ($R)"
[ "$(get after_ms "$C")" -lt 2000 ] && pass "control: undrained, the truncate freed under the walk ($(get after_ms "$C") ms)" ||
    fail "control: the truncate waited anyway -- the suite does not isolate the drain ($C)"
ct_exit
