#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub holds sets only where needed, frees runs, reads ahead what it reads
#
# Three costs of a scrub cycle (audit 2026-11-14 M3, L1, L2):
#   M3 a reference and a candidate bitmap for every owned Block Group,
#      held for the whole cycle: 64 KiB per owned GiB;
#   L1 one free call per leaked block, each re-resolving the group and
#      taking the allocation mutex;
#   L2 every inode block read ahead, allocated or not, and on the fresh
#      pass dropped again right after.
# Now the sets are built a budgeted batch at a time and kept only for
# groups with a candidate, confirmed blocks are freed as runs, and only
# allocated inodes are read ahead.
#
# 40 contiguous blocks are leaked in group 0 of a three-group volume, the
# budget is one group's set; a 2 s scrub runs:
#   1. exactly the 40 blocks are reclaimed, and fsck is clean after;
#   2. they went back in one or two free calls, not 40;
#   3. the cycle held at most two groups' worth of sets;
#   4. a cycle read ahead about the allocated inodes, not all 1024.
#
# DISCRIMINATION: scrub_old_shape restores all three.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/scrub_old_shape ] || { skip "scrub_old_shape is missing"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"
MNT="$(ct_mnt ssh)"
ct_track mnt "$MNT"
ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
ct_param_set scrub_old_shape 0
ct_param_set scrub_ref_budget_kb 16
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set scrub 0 # armed per probe, below
P=/sys/module/cetrafs/parameters

# <old 0|1> -> "<reclaimed> <free calls> <set bytes peak> <readahead per cycle> <fsck ok|bad>"
probe() {
    local img dev pd rec0 fc0 ra0 c0 rec fc peak ra c ok
    img="$(ct_image 1700 "ssh$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    "$LEAK" "$dev" 0 100 40 >/dev/null
    echo "$1" >$P/scrub_old_shape
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    v() { sed -n "s/^$1: //p" "$pd/info"; }
    rec0="$(v scrub_reclaimed)"
    fc0="$(v scrub_free_calls)"
    echo 1 >$P/scrub
    for _ in $(seq 1 30); do
        [ $(($(v scrub_reclaimed) - rec0)) -ge 40 ] && break
        sleep 1
    done
    rec=$(($(v scrub_reclaimed) - rec0))
    fc=$(($(v scrub_free_calls) - fc0))
    peak="$(v scrub_set_bytes_peak)"
    # A whole later cycle, start to end, for the read-ahead count.
    c0="$(v scrub_cycles)"
    for _ in $(seq 1 20); do [ "$(v scrub_cycles)" != "$c0" ] && break; sleep 0.2; done
    ra0="$(v scrub_inode_readahead)"
    c0="$(v scrub_cycles)"
    for _ in $(seq 1 40); do [ "$(v scrub_cycles)" != "$c0" ] && break; sleep 0.2; done
    ra=$(($(v scrub_inode_readahead) - ra0))
    echo 0 >$P/scrub
    echo 0 >$P/scrub_old_shape
    ct_umount "$MNT" >/dev/null
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$rec $fc $peak $ra $ok"
}
read -r REC FC PEAK RA OK <<<"$(probe 0)"
read -r REC0 FC0 PEAK0 RA0 OK0 <<<"$(probe 1)"
log "new shape: reclaimed $REC in $FC call(s), sets peak $PEAK B, $RA inode read-aheads per cycle, fsck $OK"
log "old shape: reclaimed $REC0 in $FC0 call(s), sets peak $PEAK0 B, $RA0 inode read-aheads per cycle, fsck $OK0"
[ "$REC0" = 40 ] || fail "setup: the old shape reclaimed $REC0 of the 40 leaked blocks"
[ "$REC" = 40 ] && [ "$OK" = ok ] && pass "1: exactly the 40 leaked blocks were reclaimed, fsck clean" ||
    fail "1: reclaimed $REC of 40, fsck $OK"
[ "$FC" -le 2 ] && pass "2: they went back in $FC free call(s)" || fail "2: $FC free calls for one 40-block run"
[ "$PEAK" -le 32768 ] && pass "3: the cycle held $PEAK bytes of sets at most" ||
    fail "3: the cycle held $PEAK bytes of sets -- every group's, all cycle"
[ "$RA" -le 64 ] && pass "4: a cycle read ahead $RA inode blocks" || fail "4: a cycle read ahead $RA inode blocks"
[ "$FC0" -ge 40 ] && [ "$PEAK0" -ge $((PEAK * 2)) ] && [ "$RA0" -ge $((RA * 4)) ] &&
    pass "control: the old shape takes $FC0 calls, $PEAK0 bytes, $RA0 read-aheads -- the suite discriminates" ||
    fail "control: the old shape took $FC0 calls, $PEAK0 bytes, $RA0 read-aheads -- the suite cannot tell"
ct_exit
