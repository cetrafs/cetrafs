#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a convert's tree reserve is kept for the next convert, guarded from the scrub, and given back at close
#
# Every convert that may have to append through the tree reserves four
# tree blocks first (FD-1), zeroes and writes them (thin provisioning,
# de028da), and freed what the append did not take when it ended -- so
# the next convert allocated and wrote them all over again (review F-5,
# BM-55). The reserve is now kept between converts while the file is
# open for write, published in the reservation registry while held
# (set, named by nothing: a leak to the scrub otherwise), and given back
# at the write close.
#
# Full leaves (tree_build_full, then a punch to rebuild) make every
# convert need room; 120 first writes into preallocated blocks through
# one held fd.
#   1. the 120 converts take few tree blocks from the allocator (the
#      reserve once, then what the appends used): under 30;
#   2. with the fd still open, two scrub cycles reclaim nothing;
#   3. after the close and unmount, fsck finds no leaked block.
#
# DISCRIMINATION: tree_resv_keep_off=1 (freed after every convert): 1
# takes 4 per convert. tree_resv_unregistered=1 (kept, unguarded): 2
# reclaims the kept blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_resv_keep_off tree_resv_unregistered tree_build_full; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt trk)"
ct_track mnt "$MNT"
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set tree_build_full 0
ct_param_set tree_resv_keep_off 0
ct_param_set tree_resv_unregistered 0
P=/sys/module/cetrafs/parameters

# <keep_off 0|1> <unregistered 0|1> -> "allocs=<n> cycles=<n> reclaimed=<n> leaked=<n> fsck=<clean|ERR>"
round() {
    local dev proc t a0 a1 c0 c1 r0 r1 out leaked
    dev="$(ct_dev 900 "trk$1$2")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    echo 1 >$P/tree_build_full
    fallocate -l $((8192 * 4096)) "$MNT/f"
    python3 -I - "$MNT/f" <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096); m.write(b"x" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
for b in range(0, 4000, 4):
    os.pwrite(fd, m, b * 4096)
os.close(fd)
PY
    fallocate -p -o $((8 * 4096)) -l 4096 "$MNT/f" # rebuilt with full leaves
    echo 0 >$P/tree_build_full
    sync
    echo "$1" >$P/tree_resv_keep_off
    echo "$2" >$P/tree_resv_unregistered
    t="$(ct_tmp "trk-ctl$1$2")"
    rm -rf "$t"; mkdir -p "$t"
    a0="$(sed -n 's/^tree_allocs: //p' "$proc/info")"
    python3 -I - "$MNT/f" "$t" <<'PY' &
import os, sys, mmap, time
d = sys.argv[2]
m = mmap.mmap(-1, 4096); m.write(b"y" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
for k in range(120):
    os.pwrite(fd, m, (2 + 32 * k) * 4096)
open(os.path.join(d, "w"), "w").close()
while not os.path.exists(os.path.join(d, "more")):
    time.sleep(0.05)
for k in range(40):
    os.pwrite(fd, m, (6 + 32 * k) * 4096)
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    a1="$(sed -n 's/^tree_allocs: //p' "$proc/info")"
    # the reserve is held now: two scrub cycles over it
    c0="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    r0="$(sed -n 's/^scrub_reclaimed: //p' "$proc/info")"
    echo 1 >$P/scrub
    wait_for 40 '[ "$(sed -n "s/^scrub_cycles: //p" "'"$proc/info"'")" -ge '"$((c0 + 2))"' ]' || true
    echo 0 >$P/scrub
    c1="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    r1="$(sed -n 's/^scrub_reclaimed: //p' "$proc/info")"
    touch "$t/more"
    wait "$wpid" || true
    echo 0 >$P/tree_resv_keep_off
    echo 0 >$P/tree_resv_unregistered
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    leaked="$(sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode.*/\1/p' <<<"$out" | head -1)"
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    echo "allocs=$((a1 - a0)) cycles=$((c1 - c0)) reclaimed=$((r1 - r0)) leaked=${leaked:-0} fsck=$out"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0 0)"
log "kept: $R"
C="$(round 1 0)"
log "control (freed after every convert): $C"
U="$(round 0 1)"
log "control (kept, unregistered): $U"
[ "$(get allocs "$C")" -ge 240 ] || { fail "setup: freed per convert, the 120 converts took only $(get allocs "$C") tree blocks -- they did not need room ($C)"; ct_exit; }
pass "setup: freed after every convert, the 120 converts took $(get allocs "$C") tree blocks"
[ "$(get allocs "$R")" -lt 30 ] && pass "1: kept between converts, they took $(get allocs "$R")" ||
    fail "1: kept, the converts still took $(get allocs "$R") tree blocks"
[ "$(get cycles "$R")" -ge 2 ] && [ "$(get reclaimed "$R")" = 0 ] &&
    pass "2: two scrub cycles over the held reserve reclaimed nothing" || fail "2: over the held reserve: $R"
[ "$(get leaked "$R")" = 0 ] && [ "$(get fsck "$R")" = clean ] && pass "3: given back at the close: fsck finds nothing leaked" ||
    fail "3: after the close: $R"
[ "$(get cycles "$U")" -ge 2 ] && [ "$(get reclaimed "$U")" -gt 0 ] &&
    pass "control: kept but unregistered, the scrub reclaimed $(get reclaimed "$U") of the reserve's blocks" ||
    fail "control: unregistered, the scrub reclaimed nothing ($U) -- it never judged the reserve"
ct_exit
