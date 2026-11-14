#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's silence is not counted across the observer's own outage
#
# A peer is judged dead when its heartbeat counter sits still for a
# window of OUR clock. An observer stalled on the same dead LUN as the
# peer used to count the whole stall as the peer's silence: at its first
# look back the peer was "dead" while the peer's own renewal was still
# queued behind the same outage -- two nodes could fence each other in
# the same second (audit 2026-11-14 O2).
#
# Now our own renewals say whether we could see the device: while ours
# are overdue no verdict is given, and once they land again the watch
# counts from then.
#
# A planted peer row (1 s beat) is watched by a mount on a compressed
# 1 s beat and 3 s window (4 s with the peer's floor). This node's own
# renewals then fail for 7 s (hb_renew_fail; the lease is off, it is not
# what is measured); the peer's row never moves.
#   1. read 1 s after our renewals come back: the peer is not stale yet;
#   2. a full window later it is -- the verdict is delayed, not lost.
#
# DISCRIMINATION: peer_watch_no_restart counts the silence across our
# outage, as before; 1 must then read stale.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
for k in peer_watch_no_restart hb_renew_fail lease_disable; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

DEVS=("$(ct_dev 560 pwog0)" "$(ct_dev 560 pwog1)") # one per run: a planted row stalls a later mkfs
MNT="$(ct_mnt pwog)"
ct_track mnt "$MNT"
compress_timing
ct_param_set lease_disable 1
ct_param_set peer_watch_no_restart 0
ct_param_set hb_renew_fail 0
peer() { grep '^node 1:' "/proc/fs/cetrafs/$(basename "$DEV")/cluster" | grep -o 'stale=[a-z]*'; }

# <no_restart 0|1> -> "<verdict after the outage> <verdict a window later>"
probe() {
    DEV="${DEVS[$1]}"
    ct_mkfs_small "$DEV" >/dev/null
    echo "$1" >/sys/module/cetrafs/parameters/peer_watch_no_restart
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    # Planted after the mount: the no-CAW gate would watch it otherwise.
    "$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" 1 >/dev/null
    sleep 2
    [ "$(peer)" = stale=no ] || { fail "setup: the planted peer reads $(peer) before anything happened"; ct_exit; }
    echo 1 >/sys/module/cetrafs/parameters/hb_renew_fail
    sleep 7
    echo 0 >/sys/module/cetrafs/parameters/hb_renew_fail
    sleep 1.5
    local a b
    a="$(peer)"
    sleep 6
    b="$(peer)"
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/peer_watch_no_restart
    echo "$a $b"
}

read -r A B <<<"$(probe 0)"
[ "$A" = stale=no ] && pass "1: right after our own outage the silent peer is not yet stale" ||
    fail "1: the peer read $A at our first look back -- our own outage was counted as its silence"
[ "$B" = stale=yes ] && pass "2: a window later the silent peer is stale -- the verdict is delayed, not lost" ||
    fail "2: a window after our outage the silent peer still reads $B"
read -r A B <<<"$(probe 1)"
[ "$A" = stale=yes ] && pass "control: counting across our outage calls the peer dead at once -- the suite discriminates" ||
    fail "control: with peer_watch_no_restart the peer read $A -- the suite cannot tell"
ct_exit
