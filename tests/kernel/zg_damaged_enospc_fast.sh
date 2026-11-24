#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a damaged Zone Group record costs one tear budget, not one per failed allocation
#
# A Zone Group record that fails its checksum on every read is left
# alone: no claim, no release, reported once (zg_record_damaged.sh). But
# every read of it still paid the whole torn-read retry budget, about a
# quarter of a second, and the allocator reads every record it might
# claim on every ENOSPC. A node that owned no group behind one damaged
# record took over half a second per failed block: a write exercise of a
# few dozen allocations outran a 30 s budget (found by fuzz-mount-fields).
# A record marked unreadable is now answered from the mark, and read
# again at most every 30 s (cetrafs_sb_zg_unreadable_skip()).
#
# One Zone Group, its record's cold half damaged before the mount: the
# node owns nothing, and every allocating write fails with ENOSPC.
#   setup: the mount succeeds and the writes fail with ENOSPC;
#   1. twenty failed writes take well under a second each.
#
# DISCRIMINATION: zg_unreadable_recheck_always=1 (as before): each failed
# write pays the budget again.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_unreadable_recheck_always ] ||
    { skip "zg_unreadable_recheck_always is missing"; ct_exit; }
ct_param_set zg_unreadable_recheck_always 0
ct_param_set zg_unreadable_fatal 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
POKE="$(ct_helper csum_poke)"
MNT="$(ct_mnt zgdef)"
ct_track mnt "$MNT"
N=20

# <tag> <always 0|1> -> RES "<ms for N writes> <ENOSPC count>"
round() {
    local img dev t0 t1 i nospc=0 out
    img="$(ct_image 1200 "zgdef$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    "$POKE" "$img" zg-cold 0 >/dev/null
    blockdev --flushbufs "$dev"
    mount -t cetrafs "$dev" "$MNT" 2>/dev/null || { RES="setup-mount"; return; }
    ct_param_set zg_unreadable_recheck_always "$2"
    t0="$(date +%s%N)"
    for i in $(seq "$N"); do
        out="$(dd if=/dev/zero of="$MNT/w$i" bs=4k count=1 conv=fsync status=none 2>&1 || true)"
        grep -q 'No space' <<<"$out" && nospc=$((nospc + 1))
    done
    t1="$(date +%s%N)"
    ct_param_set zg_unreadable_recheck_always 0
    ct_umount "$MNT"
    RES="$(((t1 - t0) / 1000000)) $nospc"
}

round f 0
read -r FMS FN <<<"$RES"
log "fixed: $N failed writes took ${FMS} ms (ENOSPC $FN)"
round c 1
read -r CMS CN <<<"$RES"
log "control (re-read every time): $N failed writes took ${CMS} ms (ENOSPC $CN)"
case "$FMS" in setup-*) fail "setup: $FMS"; ct_exit ;; esac
case "$CMS" in setup-*) fail "control setup: $CMS"; ct_exit ;; esac
[ "$FN" = "$N" ] && [ "$CN" = "$N" ] ||
    { fail "setup: the writes did not all fail with ENOSPC (fixed $FN, control $CN of $N)"; ct_exit; }
# Fixed: one budget at most (the first read after the mount's own may
# fall in a recheck), plus the writes. Control: one budget per write.
[ "$FMS" -lt $((N * 100)) ] && pass "1: $N failed writes took ${FMS} ms" ||
    fail "1: $N failed writes took ${FMS} ms -- the damaged record is re-read per allocation"
[ "$CMS" -ge $((N * 200)) ] && pass "control: re-read every time, the same writes took ${CMS} ms" ||
    fail "control: ${CMS} ms -- the staging does not make the record's reads the cost"
ct_exit
