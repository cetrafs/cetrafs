#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub keeps candidates as runs, under a per-cycle budget
#
# A candidate was a bitmap of the whole Block Group, kept from pass 1 to
# the confirming pass for every group that had one, however few leaks it
# held (audit 2026-11-14 M3): 16 KiB per such group on this geometry. The
# candidates are now runs of consecutive blocks, and a cycle's runs share
# one budget; a group that would exceed it keeps none this cycle and reclaims
# nothing there, which is the safe direction.
#
# Setup: one leaked block in each of the three Block Groups of a fresh
# volume, and a live file. Checks:
#   1. the three leaks are reclaimed, the live file reads back unchanged,
#      and fsck is clean (the setup produced candidates in every group);
#   2. the cycle held at most two groups' worth of sets, candidates included;
#   3. the control (scrub_cand_bitmap) holds a bitmap per group with a
#      candidate, and its peak is at least twice the run shape's;
#   4. with the budget at 1 KiB, a group of 200 separated leaks is deferred
#      (scrub_cand_deferred rises), its blocks are NOT freed that cycle, and
#      the other groups still reclaim; with the budget restored, the next
#      cycle reclaims all 202 leaks and fsck is clean.
#
# DISCRIMINATION: scrub_cand_bitmap restores the per-group bitmap, which 3
# and 4 measure.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/scrub_cand_bitmap ] || { skip "scrub_cand_bitmap is missing"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"
MNT="$(ct_mnt scand)"
ct_track mnt "$MNT"
ct_param_set scrub_cand_bitmap 0
ct_param_set scrub_cand_budget_kb 4096
ct_param_set scrub_ref_budget_kb 16
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set scrub 0 # armed per probe, below
P=/sys/module/cetrafs/parameters

# A live file, written after mount so the allocator keeps off the leaks.
live_sum() { sha256sum "$1" | awk '{print $1}'; }

# <cand_bitmap 0|1> -> "<reclaimed> <peak bytes> <deferred> <live ok|bad> <fsck ok|bad>"
probe() {
    local img dev bg rec0 rec pk df sum0 sum1 ok lv
    img="$(ct_image 1700 "scand$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    for bg in 0 1 2; do "$LEAK" "$dev" "$bg" 100 1 >/dev/null; done
    echo "$1" >$P/scrub_cand_bitmap
    ct_mount "$dev" "$MNT"
    local pd
    pd="$(ct_procdir "$dev")"
    v() { sed -n "s/^$1: //p" "$pd/info"; }
    head -c 2097152 /dev/urandom >"$MNT/live"
    sync
    sum0="$(live_sum "$MNT/live")"
    rec0="$(v scrub_reclaimed)"
    echo 1 >$P/scrub
    for _ in $(seq 1 30); do
        [ $(($(v scrub_reclaimed) - rec0)) -ge 3 ] && break
        sleep 1
    done
    rec=$(($(v scrub_reclaimed) - rec0))
    pk="$(v scrub_set_bytes_peak)"
    df="$(v scrub_cand_deferred)"
    echo 0 >$P/scrub
    sleep 3 # a cycle already under way finishes before the next probe reads
    sum1="$(live_sum "$MNT/live")"
    [ "$sum0" = "$sum1" ] && lv=ok || lv=bad
    echo 0 >$P/scrub_cand_bitmap
    ct_umount "$MNT" >/dev/null
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$rec $pk $df $lv $ok"
}

read -r REC PEAK DEF LIVE OK <<<"$(probe 0)"
read -r REC1 PEAK1 DEF1 LIVE1 OK1 <<<"$(probe 1)"
log "run shape: reclaimed $REC, peak $PEAK B, deferred $DEF, live $LIVE, fsck $OK"
log "bitmap control: reclaimed $REC1, peak $PEAK1 B, deferred $DEF1, live $LIVE1, fsck $OK1"
[ "$REC" = 3 ] && [ "$LIVE" = ok ] && [ "$OK" = ok ] &&
    pass "1: the three leaks were reclaimed, the live file is unchanged, fsck clean" ||
    fail "1: reclaimed $REC of 3, live $LIVE, fsck $OK"
[ "$PEAK" -le 32768 ] && pass "2: the cycle held $PEAK bytes of sets at most" ||
    fail "2: the cycle held $PEAK bytes of sets -- a bitmap per candidate group"
[ "$REC1" = 3 ] && [ "$PEAK1" -ge $((PEAK * 2)) ] && [ "$LIVE1" = ok ] && [ "$OK1" = ok ] &&
    pass "3: the bitmap control holds $PEAK1 bytes, the run shape $PEAK -- the suite discriminates" ||
    fail "3: the bitmap control held $PEAK1 bytes against the run shape's $PEAK (reclaimed $REC1)"
[ "$DEF" = 0 ] || fail "3: $DEF group(s) deferred under the default budget"

# 4. the budget. Group 0 gets 200 leaks, each separated by an allocated block,
# so it has 200 runs; group 1 and 2 one each.
img="$(ct_image 1700 scandb)"
dev="$(ct_loop "$img")"
ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
for i in $(seq 0 199); do "$LEAK" "$dev" 0 $((100 + 2 * i)) 1 >/dev/null; done
"$LEAK" "$dev" 1 100 1 >/dev/null
"$LEAK" "$dev" 2 100 1 >/dev/null
echo 0 >$P/scrub_cand_bitmap
ct_param_set scrub_cand_budget_kb 1
ct_mount "$dev" "$MNT"
pd="$(ct_procdir "$dev")"
v() { sed -n "s/^$1: //p" "$pd/info"; }
head -c 2097152 /dev/urandom >"$MNT/live"
sync
sum0="$(live_sum "$MNT/live")"
rec0="$(v scrub_reclaimed)"
df0="$(v scrub_cand_deferred)"
echo 1 >$P/scrub
for _ in $(seq 1 30); do
    [ $(($(v scrub_reclaimed) - rec0)) -ge 2 ] && break
    sleep 1
done
sleep 3
echo 0 >$P/scrub
sleep 3
DEFER=$(($(v scrub_cand_deferred) - df0))
REC_SMALL=$(($(v scrub_reclaimed) - rec0))
log "small budget: $DEFER deferral(s) of the 200-run group, reclaimed $REC_SMALL of 202"
[ "$DEFER" -ge 1 ] && pass "4: a group over the 1 KiB budget was deferred" ||
    fail "4: no group deferred under a 1 KiB budget -- the budget is not enforced"
[ "$REC_SMALL" = 2 ] && pass "4: the deferred group's 200 leaks were not freed that cycle; the other two were" ||
    fail "4: reclaimed $REC_SMALL in the budget cycle (want 2: groups 1 and 2 only)"

ct_param_set scrub_cand_budget_kb 4096
echo 1 >$P/scrub
for _ in $(seq 1 60); do
    [ $(($(v scrub_reclaimed) - rec0)) -ge 202 ] && break
    sleep 1
done
echo 0 >$P/scrub
sleep 3
REC_ALL=$(($(v scrub_reclaimed) - rec0))
sum1="$(live_sum "$MNT/live")"
ct_umount "$MNT" >/dev/null
ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
[ "$REC_ALL" = 202 ] && [ "$ok" = ok ] && [ "$sum0" = "$sum1" ] &&
    pass "4: with the budget restored the next cycle reclaimed all 202, live file unchanged, fsck clean" ||
    fail "4: reclaimed $REC_ALL of 202, fsck $ok, live $( [ "$sum0" = "$sum1" ] && echo ok || echo bad)"
ct_exit
