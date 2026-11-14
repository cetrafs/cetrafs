#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the extent cache remembers several extents, so alternating between them hits
#
# The extent cache kept ONE extent per inode (P14). A workload that moves
# between several extents of a fragmented file -- a guest's random I/O over
# its image -- missed on every switch and walked the tree again. It now keeps
# up to 16 (ext_cache_entries), under the same record key and drops.
#
# Setup: the fragmented file of extent_cache.sh (islands, holes filled), then
# a rewrite that visits 8 islands round-robin, one 4 KiB block at a time.
# Each visit is a different extent: a one-entry cache misses every time, a
# multi-entry cache hits from the second pass on.
#   1. fixed (16 entries): most lookups hit;
#   2. control (ext_cache_entries=1): the same workload hits almost never;
#   3. the bytes written read back intact after a remount (the cache answers
#      the same blocks as the tree does).
#
# DISCRIMINATION: ext_cache_entries=1 is assertion 2 itself.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/ext_cache_entries ] || { skip "ext_cache_entries is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt extce)"
ct_track mnt "$MNT"
ct_param_set ext_cache_entries 16

ROUND="$(ct_tmp extce-round.py)"
cat >"$ROUND" <<'PY'
import os, sys
p, pas = sys.argv[1], int(sys.argv[2])
ISL = 65536
f = os.open(p, os.O_RDWR)
pages = [8 * i for i in range(8)]           # 8 islands, 16 blocks each
for rnd in range(pas):
    # consecutive writes switch island every time, and the cache is dropped
    # each round, so every block takes the mapping path (a lookup)
    for blk in range(0, 16, 4):
        for isl in pages:
            os.pwrite(f, bytes([(rnd + isl) & 0xff]) * 4096, isl * ISL + blk * 4096)
    os.fsync(f)
    os.posix_fadvise(f, 0, 0, os.POSIX_FADV_DONTNEED)
os.close(f)
PY

# <entries> -> "<hits> <misses>" for the rewrite, on a fresh volume
probe() {
    local img dev hits0 hits1 miss0 miss1
    img="$(ct_image 560 "extce$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    local proc="$(ct_procdir "$dev")/info"
    python3 - "$MNT/frag" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.ftruncate(f, 64 << 20)
buf = b'\0' * 65536
for i in range(0, 1024, 4):
    os.pwrite(f, buf, i * 65536)
os.fsync(f)
os.close(f)
PY
    dd if=/dev/zero of="$MNT/frag" bs=64k count=1024 conv=notrunc,fdatasync status=none
    sync
    echo "$1" >$P/ext_cache_entries
    hits0="$(sed -n 's/^ext_cache_hits: //p' "$proc")"
    miss0="$(sed -n 's/^ext_cache_misses: //p' "$proc")"
    python3 "$ROUND" "$MNT/frag" 4
    hits1="$(sed -n 's/^ext_cache_hits: //p' "$proc")"
    miss1="$(sed -n 's/^ext_cache_misses: //p' "$proc")"
    # the bytes, after a remount: every block holds the last round
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    local bad
    bad="$(python3 - "$MNT/frag" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_RDONLY)
bad = 0
for isl in [8 * i for i in range(8)]:
    for blk in range(0, 16, 4):
        if os.pread(f, 4096, isl * 65536 + blk * 4096) != bytes([(3 + isl) & 0xff]) * 4096:
            bad += 1
print(bad)
PY
)"
    ct_umount "$MNT"
    echo "$((hits1 - hits0)) $((miss1 - miss0)) $bad"
}

read -r H M BAD <<<"$(probe 16)"
log "fixed (16 entries): $H hits, $M misses, $BAD bad block(s) after remount"
[ "$BAD" = 0 ] && pass "3: the blocks written through the cache read back after a remount" ||
    fail "3: $BAD block(s) read back wrong"
[ $((H + M)) -gt 0 ] || fail "setup: the rewrite made no extent lookups at all"
[ "$H" -gt "$M" ] && pass "1: with 16 remembered extents the round-robin rewrite mostly hits ($H hits, $M misses)" ||
    fail "1: $H hits and $M misses with 16 entries -- the extents are not remembered together"
read -r H1 M1 BAD1 <<<"$(probe 1)"
log "control (1 entry): $H1 hits, $M1 misses"
[ $((H1 + M1)) -gt 0 ] && [ "$H1" -lt $((M1 / 4 + 1)) ] &&
    pass "2: with one remembered extent the same workload misses on every switch -- the suite discriminates" ||
    fail "2: one entry gave $H1 hits and $M1 misses -- the suite cannot tell"
ct_exit
