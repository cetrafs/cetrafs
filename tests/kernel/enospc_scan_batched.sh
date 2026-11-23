#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation that finds the volume full reads the tables in batches
#
# Before answering ENOSPC the allocator looks for a Zone Group to claim
# and a free Block Group to take, twice (once more after waiting out a
# release): every Zone Group record and every Block Group descriptor it
# does not own, each a serial forced-fresh read, all under the writer's
# locks -- seconds per failed write on a large volume (audit 2026-11-14
# A4). Both tables are now read as batches.
#
# A volume of 16 Zone Groups is filled by fallocate; then 5 writes fail
# with ENOSPC, and the loop device's completed reads are counted. The
# measure is the reads the batching SAVES, not a ratio: each failed write
# also probes every owned pending-free queue before its answer (one
# batched read per queue, the same in both modes), and that fixed cost
# halved the ratio without touching the scans.
#
# Nothing is queued, so the drain before ENOSPC must apply nothing and
# send the allocator round again for nothing: enospc_drain_rescans stays
# 0. It counted the blocks it READ as frees applied, and rescanned on
# every ENOSPC.
#
# DISCRIMINATION: zg_prefetch_off reads each record on its own, as
# before: two passes of 16 records, ~15 requests more each, per failed
# write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_prefetch_off ] || { skip "zg_prefetch_off is missing"; ct_exit; }
IMG="$(ct_image 16384 esb)" # sparse: 16 Block Groups of 1 GiB
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt esb)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 16 -b 1024 -J 0 -N 1024 -f >/dev/null
ct_param_set zg_prefetch_off 0
# The scans are what this measures: both passes run, as they did when it
# was written (enospc_one_pass.sh is the suite for dropping the second
# when no release ran -- with one pass the fixed reads of each write are
# most of the count, and the ratio stops meaning anything).
ct_param_set enospc_always_rescan 1
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
FREE="$(stat -f -c '%a * %S' "$MNT" | bc)"
fallocate -l "$FREE" "$MNT/fill" 2>/dev/null || fallocate -l $((FREE - 64 * 1048576)) "$MNT/fill"
while fallocate -l 4M "$MNT/top$RANDOM" 2>/dev/null; do :; done
sync
reads() { awk '{print $1}' "/sys/block/$(basename "$DEV")/stat"; }
run() {
    local r0 fails=0
    r0="$(reads)"
    for i in 1 2 3 4 5; do
        dd if=/dev/zero of="$MNT/w$1-$i" bs=4096 count=1 conv=fsync status=none 2>/dev/null || fails=$((fails + 1))
    done
    echo "$(($(reads) - r0)) $fails"
}
DR0="$(sed -n 's/^enospc_drain_rescans: //p' "$(ct_procdir "$DEV")/info")"
read -r R F <<<"$(run 0)"
DR1="$(sed -n 's/^enospc_drain_rescans: //p' "$(ct_procdir "$DEV")/info")"
ct_param_set zg_prefetch_off 1
read -r R0 F0 <<<"$(run 1)"
ct_param_set zg_prefetch_off 0
ct_umount "$MNT"
log "5 writes on a full volume: $R reads batched ($F failed), $R0 one record at a time ($F0 failed)"
[ "$F" = 5 ] && [ "$F0" = 5 ] || fail "setup: $F / $F0 of 5 writes failed -- the volume was not full"
[ "$R0" -ge 160 ] || fail "setup: the serial scans took only $R0 reads -- not the 16-record table"
[ $((R0 - R)) -ge 150 ] && pass "a full-volume ENOSPC reads the tables in batches ($R against $R0 one at a time)" ||
    fail "$R reads batched against $R0 serial -- the scans are not batched"
[ -n "$DR0" ] && [ "$DR1" = "$DR0" ] && pass "the drain before ENOSPC applied nothing and sent nobody round again" ||
    fail "enospc_drain_rescans $DR0 -> $DR1 over 5 failed writes with nothing queued"
ct_exit
