#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount's claim sweep renews the lease per record, not per bitmap block
# ct-timeout: 300
#
# A mount after an unclean exit sweeps this node's claims off every
# allocated record before the heartbeat runs, renewing the lease as it
# goes. It renewed once per inode-bitmap block -- 32768 numbers -- and a
# cold record read is milliseconds on a real LUN: about 19,000 allocated
# inodes outlasted the 105 s lease, and the mount stopped (audit
# 2026-11-15 BM-21). It now renews per record (at most once a beat).
#
# 40 files, each record read held 200 ms (sweep_read_stall_ms), a 1 s
# beat and its 3 s lease: 8 s of sweep.
#   1. the mount completes, its lease kept, and the volume writes.
#
# DISCRIMINATION: sweep_beat_per_block=1 -- the lease runs out mid-sweep
# and the mount is refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt sweepbeat)"
ct_track mnt "$MNT"
ct_param_set sweep_beat_per_block 0
ct_param_set sweep_read_stall_ms 0
compress_timing
fresh() { DEV="$(ct_loop "$(ct_image 560 "sweepbeat$1")")"; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <per_block 0|1> -> RES
round() {
    local me mark rc=0 i
    fresh "$1"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    for i in $(seq 1 40); do : >"$MNT/f$i"; done
    sync
    me="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    ct_umount "$MNT"
    "$NPOKE" "$DEV" "$me" --depart 0 >/dev/null # left uncleanly: the mount sweeps
    blockdev --flushbufs "$DEV"
    echo "$2" >/sys/module/cetrafs/parameters/sweep_beat_per_block
    echo 200 >/sys/module/cetrafs/parameters/sweep_read_stall_ms
    mark="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT" 2>/dev/null || rc=$?
    echo 0 >/sys/module/cetrafs/parameters/sweep_read_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/sweep_beat_per_block
    RES="mounted=$(mountpoint -q "$MNT" && echo yes || echo no) rc=$rc"
    dmesg_since "$mark" | grep -q "mounted OK" && RES="$RES ok=yes" || RES="$RES ok=no"
    if mountpoint -q "$MNT"; then
        echo x >"$MNT/g" && sync && RES="$RES write=ok" || RES="$RES write=fail"
        ct_umount "$MNT"
    fi
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (a renewal per bitmap block): $C"
[ "$(field mounted "$F")" = yes ] && [ "$(field ok "$F")" = yes ] && [ "$(field write "$F")" = ok ] &&
    pass "1: the mount kept its lease through an 8 s sweep and writes ($F)" || fail "1: $F"
[ "$(field ok "$C")" = no ] && pass "control: as before, the lease ran out mid-sweep and the mount was refused ($C)" ||
    fail "control: $C -- the suite does not reach the lease"
ct_exit
