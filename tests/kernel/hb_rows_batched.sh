#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the heartbeat sweep reads the Node Registry as one batch
#
# Every tick the dead-peer sweep read each of the 64 registry rows with
# its own forced-fresh round trip, and each registered row again to
# judge it (audit 2026-11-14 P13, C10). It now reads the registry as one
# batch and judges from it; a row the batch shows stale is judged again
# from a fresh read before anything acts on it.
#
# On a 1 s tick, the sweep's registry round trips (hb_row_reads in info)
# per sweep (hb_sweeps) are counted.
#
# DISCRIMINATION: hb_rows_serial reads each row on its own.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/hb_rows_serial ] || { skip "hb_rows_serial is missing"; ct_exit; }
MNT="$(ct_mnt hrb)"
ct_track mnt "$MNT"
ct_param_set hb_rows_serial 0
compress_timing
P=/sys/module/cetrafs/parameters

# <serial 0|1> -> "<round trips> <sweeps>"
probe() {
    local img dev pd r0 s0
    img="$(ct_image 560 "hrb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    echo "$1" >$P/hb_rows_serial
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    sleep 2
    r0="$(sed -n 's/^hb_row_reads: //p' "$pd/info")"
    s0="$(sed -n 's/^hb_sweeps: //p' "$pd/info")"
    sleep 5
    echo "$(($(sed -n 's/^hb_row_reads: //p' "$pd/info") - r0)) $(($(sed -n 's/^hb_sweeps: //p' "$pd/info") - s0))"
    echo 0 >$P/hb_rows_serial
    ct_umount "$MNT" >/dev/null
}
read -r R S <<<"$(probe 0)"
read -r R0 S0 <<<"$(probe 1)"
log "registry round trips: $R in $S sweeps batched, $R0 in $S0 one by one"
[ "$S" -ge 2 ] && [ "$S0" -ge 2 ] || fail "setup: only $S / $S0 sweeps ran in 5 s"
[ "$R" -le $((S * 2)) ] && pass "a sweep makes $R round trips in $S sweeps -- one batch each" ||
    fail "$R round trips in $S sweeps -- still a read per row"
[ "$R0" -ge $((S0 * 32)) ] && pass "control: one by one it is $R0 in $S0 sweeps -- the suite discriminates" ||
    fail "control: $R0 in $S0 sweeps -- the suite cannot tell"
ct_exit
