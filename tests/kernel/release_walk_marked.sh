#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the per-tick empty-group release looks only at groups that may be empty
#
# Every heartbeat tick the release walked the whole Block Group table
# once per owned Zone Group, and CRC'd every owned descriptor to learn
# it still held data (audit 2026-11-14 P13; PERFORMANCE.md invariant 5:
# nothing per tick may touch the whole table). It now visits only the
# groups credited since they were last seen in use.
#
# A 1 TiB sparse volume (2048 groups, 4 Zone Groups) on a 1 s tick; once
# the first ticks have handed the empty groups back, the release's
# visits (release_visits in info) over 4 s are counted. Then a file is
# written and removed, and its group must still be handed back.
#
# DISCRIMINATION: release_walk_all walks the whole table, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/release_walk_all ] || { skip "release_walk_all is missing"; ct_exit; }
MNT="$(ct_mnt rwm)"
ct_track mnt "$MNT"
ct_param_set release_walk_all 0
compress_timing
P=/sys/module/cetrafs/parameters

# <all 0|1> -> "<visits in 4 s at rest> <free blocks in unowned groups after the rm settled>"
probe() {
    local img dev pd v0 v1 own
    img="$(ct_image 1048576 "rwm$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 4 -b 512 -J 0 -N 1024 -f >/dev/null
    echo "$1" >$P/release_walk_all
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    # The first ticks hand the empty groups back, a discard budget at a
    # time: wait until the pool stops growing.
    local u last=x n=0
    for _ in $(seq 1 120); do
        u="$(sed -n 's/^free_data_blocks_unowned_bgs: //p' "$pd/info")"
        if [ "$u" = "$last" ]; then n=$((n + 1)); else n=0; fi
        [ "$n" -ge 3 ] && break
        last="$u"
        sleep 1
    done
    v0="$(sed -n 's/^release_visits: //p' "$pd/info")"
    sleep 4
    v1="$(sed -n 's/^release_visits: //p' "$pd/info")"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=16 status=none
    sync
    rm "$MNT/f"
    sync
    sleep 5
    own="$(sed -n 's/^free_data_blocks_unowned_bgs: //p' "$pd/info")"
    echo 0 >$P/release_walk_all
    ct_umount "$MNT" >/dev/null
    echo "$((v1 - v0)) ${own:-?}"
}
read -r V OWN <<<"$(probe 0)"
read -r V0 OWN0 <<<"$(probe 1)"
log "release visits in 4 s at rest: $V marked, $V0 whole table; free in unowned groups after the rm: $OWN / $OWN0"
[ "$V0" -ge 4096 ] || fail "setup: the whole-table walk made only $V0 visits in 4 s -- the release did not run"
[ "$V" -le 64 ] && pass "1: at rest the release visited $V groups in 4 s" ||
    fail "1: at rest the release visited $V groups in 4 s -- still the whole table"
[ "$OWN" = "$OWN0" ] && pass "2: the emptied group was handed back as before ($OWN free unowned)" ||
    fail "2: $OWN free unowned after the rm, $OWN0 with the whole-table walk -- an empty group was kept"
[ "$V0" -gt $((V * 20)) ] && pass "control: the whole-table walk visits $V0 -- the suite discriminates" ||
    fail "control: $V0 against $V -- the suite cannot tell"
ct_exit
