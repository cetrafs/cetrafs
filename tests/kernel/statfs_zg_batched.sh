#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# statfs reads the Zone Group records as one batch
#
# Free space comes from the Zone Group records, each read forced-fresh
# -- one serial round trip per record per statfs, and pvestatd polls
# statfs every ~10 s (audit 2026-11-14 P13). The table is now read as
# one batch and each record parsed from it.
#
# A volume of 16 Zone Groups; 20 statfs calls, each reading fresh
# (statfs_fresh_ms=0); the loop device's completed read requests are
# counted, and df must still agree.
#
# DISCRIMINATION: zg_prefetch_off reads each record on its own, as
# before: at least 16 requests per call.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_prefetch_off ] || { skip "zg_prefetch_off is missing"; ct_exit; }
IMG="$(ct_image 16384 szb)" # sparse: 16 Block Groups of 1 GiB
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt szb)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 16 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set zg_prefetch_off 0
# The cost of one fresh read per call: no window between them (the
# window itself is tests/kernel/statfs_fresh_once.sh).
if [ -w /sys/module/cetrafs/parameters/statfs_fresh_ms ]; then
    ct_param_set statfs_fresh_ms 0
fi
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/f" bs=1M count=8 conv=fsync status=none
reads() { awk '{print $1}' "/sys/block/$(basename "$DEV")/stat"; }
run() {
    local r0
    r0="$(reads)"
    for _ in $(seq 1 20); do stat -f -c %f "$MNT" >/dev/null; done
    echo $(($(reads) - r0))
}
F1="$(stat -f -c %f "$MNT")"
R="$(run)"
ct_param_set zg_prefetch_off 1
R0="$(run)"
F0="$(stat -f -c %f "$MNT")"
ct_param_set zg_prefetch_off 0
ct_umount "$MNT"
log "20 statfs: $R read requests batched, $R0 one record at a time; free $F1 / $F0"
[ "$R0" -ge 320 ] || fail "setup: the serial reads took only $R0 requests -- not a 16-record table, or not read fresh"
[ "$F1" = "$F0" ] && pass "both ways report the same free space ($F1)" || fail "free space differs: $F1 batched, $F0 serial"
[ "$R" -le 100 ] && pass "20 statfs took $R read requests -- the records come in one batch" ||
    fail "20 statfs took $R read requests -- still one per record"
[ "$R0" -gt $((R * 3)) ] && pass "control: reading each record alone takes $R0 -- the suite discriminates" ||
    fail "control: $R0 against $R -- the suite cannot tell"
ct_exit
