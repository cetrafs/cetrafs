#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the defrag mover copies a step as batched reads and writes, not per block
#
# Each block was read forced-fresh, written and waited for on its own:
# two synchronous round trips per block, ~256 serial ones per 512 KiB
# step, all under the file's exclusive locks (audit 2026-11-14 M1). A
# contiguous source run is now read as one batch and written with one
# wait.
#
# A file of 64 extents of 16 blocks each (interleaved with a filler) is
# defragmented by hand; the loop device's completed read requests are
# counted around it, and the data must read back.
#
# DISCRIMINATION: defrag_copy_serial copies one block per round trip, as
# before; the reads then number at least one per block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_copy_serial ] || { skip "defrag_copy_serial is missing"; ct_exit; }
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_copy_serial 0
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dcb)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters

# <serial 0|1> -> "<read requests during the defrag> <data ok|bad> <extents after>"
probe() {
    local dev r0 r1 sum ok ext
    dev="$(ct_loop "$(ct_image 560 "dcb$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    python3 - "$MNT/f" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[1] + ".fill", os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(64):
    os.pwrite(a, os.urandom(16 * 4096), i * 16 * 4096); os.fsync(a)
    os.pwrite(b, b"x" * 4096, i * 4096); os.fsync(b)
os.close(a); os.close(b)
PY
    sum="$(md5sum <"$MNT/f")"
    sync
    echo 3 >/proc/sys/vm/drop_caches
    echo "$1" >$P/defrag_copy_serial
    r0="$(awk '{print $1}' "/sys/block/$(basename "$dev")/stat")"
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || true
    r1="$(awk '{print $1}' "/sys/block/$(basename "$dev")/stat")"
    echo 0 >$P/defrag_copy_serial
    ext="$(filefrag "$MNT/f" 2>/dev/null | grep -o '[0-9]* extent' | grep -o '[0-9]*' || echo '?')"
    echo 3 >/proc/sys/vm/drop_caches
    [ "$(md5sum <"$MNT/f")" = "$sum" ] && ok=ok || ok=bad
    ct_umount "$MNT"
    echo "$((r1 - r0)) $ok $ext"
}
read -r R OK E <<<"$(probe 0)"
log "batched: $R read requests, data $OK, $E extent(s) after"
[ "${E:-99}" -le 2 ] || fail "setup: the defrag left $E extents -- it did not move the file"
[ "$OK" = ok ] && pass "the defragmented file reads back" || fail "the defragmented file's data changed"
[ "$R" -lt 512 ] && pass "1024 blocks moved in $R read requests -- batched per run" ||
    fail "1024 blocks moved in $R read requests -- still one per block"
read -r R0 OK0 _ <<<"$(probe 1)"
log "control (serial): $R0 read requests, data $OK0"
[ "$R0" -ge 1024 ] && [ "$R0" -gt $((R * 2)) ] && pass "control: per-block copying takes $R0 -- the suite discriminates" ||
    fail "control: per-block copying took $R0 against $R -- the suite cannot tell"
ct_exit
