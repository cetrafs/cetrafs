#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs -f's live-peer probe reads the registry past this host's cache
#
# mkfs -f refuses a volume a live node has mounted (or is repairing) by
# watching the Node Registry. Its first sample of the rows is the verdict
# that decides whether there is anyone to watch at all: an empty first
# sample returns "nobody" at once and the volume is formatted with no
# probe window. That sample was read through this host's page cache, and
# mkfs dropped only block 0 of it. So a row this host had read while it
# was still FREE -- and that a peer registered since, on the device --
# read FREE here, and mkfs -f formatted a volume a live node was mounted
# on (audit 2026-11-14 U2). The repair-claim probe that follows the live
# peer probe had the same first sample.
#
# Each case warms this host's cache with the whole device while the
# registry is empty, then has a peer take a row on the backing file --
# the loop device's cache is not told, exactly as with a peer on another
# host -- and runs mkfs -f. mkfs must watch the row and refuse. A setup
# assertion first proves the cache really holds the old, empty row.
#
# DISCRIMINATION (measured on the unfixed code): with the first sample
# read through the cache, mkfs sees no candidate, formats the volume and
# exits 0, in both cases.
#
# No kernel module and nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"

# case <name> <row state: 1 registered, 2 repair claim> <refusal pattern>
case_probe() {
    local name="$1" state="$2" want="$3" IMG DEV SB OUT RC BEATER

    IMG="$(ct_image 560 "probefresh-$name")"
    DEV="$(ct_loop "$IMG")"
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    blockdev --flushbufs "$DEV"
    SB="$IMG.sb"
    ct_track file "$SB"
    dd if="$IMG" of="$SB" bs=4096 count=1 status=none

    # The kernel drops a block device's cached pages when its LAST opener
    # closes, so every process below would start cold and the cache would
    # never be stale. This shell holds the device open for the case, as
    # multipathd or udev does on a real host; the cache then outlives each
    # tool's own open and close.
    exec 9<"$DEV"

    # This host reads the whole device while every row is still FREE.
    dd if="$DEV" of=/dev/null bs=1M status=none
    "$NODE_POKE" "$DEV" 1 >/dev/null
    grep -q '^state=0 ' <<<"$("$NODE_POKE" "$DEV" 1)" ||
        { fail "$name setup: row 1 is not FREE through the device: $("$NODE_POKE" "$DEV" 1)"; exec 9<&-; return; }

    # The peer takes row 1 on the backing file: the device's cache is not told.
    "$NODE_POKE" "$IMG" 1 "$state" bb "$(date +%s)" 15 >/dev/null
    grep -q "^state=$state " <<<"$(NODE_POKE_SB="$SB" "$NODE_POKE" "$IMG" 1)" ||
        { fail "$name setup: the peer row was not planted: $("$NODE_POKE" "$IMG" 1)"; exec 9<&-; return; }
    grep -q '^state=0 ' <<<"$("$NODE_POKE" "$DEV" 1)" ||
        { fail "$name setup: this host's cache does not hold the old row (the probe would see the peer)"; exec 9<&-; return; }
    pass "$name setup: this host's cache says row 1 is FREE; the peer's row is on the device only"

    export CETRAFS_PEER_PROBE_SECS=4
    (
        for _ in $(seq 1 40); do
            NODE_POKE_SB="$SB" "$NODE_POKE" "$IMG" 1 --beat >/dev/null 2>&1 || true
            sleep 0.5
        done
    ) &
    BEATER=$!
    OUT="$("$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f 2>&1)" && RC=0 || RC=$?
    kill "$BEATER" 2>/dev/null || true
    wait "$BEATER" 2>/dev/null || true
    unset CETRAFS_PEER_PROBE_SECS
    exec 9<&-

    log "$name: mkfs exited $RC"
    if [ "$RC" != 0 ] && grep -q "$want" <<<"$OUT"; then
        pass "$name: mkfs -f read the registry fresh, watched row 1, and refused"
    else
        fail "$name: mkfs -f formatted a volume a live node has in use (exit $RC): $(tail -1 <<<"$OUT")"
    fi
}

case_probe registered 1 'mounted by another node (registry row 1'
case_probe repairing 2 'is being repaired (.*registry row 1'
ct_exit
