#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# freeing an extent looks each bitmap block up once, not twice per block
#
# The direct free tested and cleared every bit through its own buffer
# lookup and buffer-lock round: two per 4 KiB block, 52 million for a
# 100 GiB image's unlink, all under alloc_mutex (audit 2026-11-14 P2).
# The loop now holds one bitmap block across its bits.
#
# A 64 MiB file (16384 blocks) is written, then removed; the free path's
# bitmap lookups (free_bmap_lookups in info) are counted:
#   1. the file's blocks all went back (the free count is restored);
#   2. the free made a handful of lookups, not one per block.
#
# DISCRIMINATION: free_per_bit looks the block up per bit, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/free_per_bit ] || { skip "free_per_bit is missing"; ct_exit; }
MNT="$(ct_mnt fbl)"
ct_track mnt "$MNT"
ct_param_set free_per_bit 0
P=/sys/module/cetrafs/parameters

# <per_bit 0|1> -> "<lookups> <free blocks before> <free blocks after>"
probe() {
    local img dev pd l0 f0 f1
    img="$(ct_image 560 "fbl$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    echo "$1" >$P/free_per_bit
    sync
    f0="$(stat -f -c %f "$MNT")"
    dd if=/dev/zero of="$MNT/f" bs=1M count=64 status=none
    sync
    l0="$(sed -n 's/^free_bmap_lookups: //p' "$pd/info")"
    rm "$MNT/f"
    sync
    for _ in $(seq 1 20); do
        f1="$(stat -f -c %f "$MNT")"
        [ "$f1" -ge "$f0" ] && break
        sleep 0.5
    done
    echo "$(($(sed -n 's/^free_bmap_lookups: //p' "$pd/info") - l0)) $f0 $f1"
    echo 0 >$P/free_per_bit
    ct_umount "$MNT" >/dev/null
}
read -r L F0 F1 <<<"$(probe 0)"
read -r L0 _ _ <<<"$(probe 1)"
log "a 16384-block free: $L bitmap lookups held per block, $L0 per bit"
[ "$F1" -ge "$F0" ] && pass "1: the free count is back where it was ($F0 -> $F1)" ||
    fail "1: the file's blocks did not all come back ($F0 -> $F1)"
[ "$L0" -ge 16384 ] || fail "setup: the per-bit free made only $L0 lookups -- the file was not freed directly"
[ "$L" -le 64 ] && pass "2: the free made $L bitmap lookups for 16384 blocks" ||
    fail "2: the free made $L bitmap lookups for 16384 blocks -- still per bit"
[ "$L0" -gt $((L * 100)) ] && pass "control: per bit it takes $L0 -- the suite discriminates" ||
    fail "control: $L0 against $L -- the suite cannot tell"
ct_exit
