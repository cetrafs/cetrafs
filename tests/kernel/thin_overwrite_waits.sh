#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a thin pool out of space makes an overwrite wait for space, not stop the mount
# ct-timeout: 400
#
# A metadata overwrite the device refused for space -- a full thin pool,
# a snapshot's copy-on-write with nowhere to go -- stopped the mount, and
# every guest on the node with it (audit 2026-11-15 A-4). As VMFS does on
# an array's out-of-space report, the writer now waits for space where it
# stands and the mount stays up; a held block a flush could not write is
# kept for the next flush; and the last close waits out a refusal of the
# pool's instead of dropping the writes it could not map (F-47).
#
# The pool is "full" for one block while TEST ONLY meta_write_nospc_block
# names it, or for the next N new blocks (new_block_nospc).
#   W. chmod overwrites the file's record: it waits while the block is
#      refused (still running, the mount not stopped, space_waits up),
#      and completes once it is not; the mode is on the device.
#   H. a record held for the heartbeat's held flush (TEST ONLY
#      test_hold_record_ino) and refused there: kept (held_refusals up),
#      the mount not stopped; written by a later flush once the pool has
#      room (nothing left listed).
#   C. buffered writes into preallocated space, the tree block the last
#      close's convert needs refused for space 40 times (several per try: one per reserved block): the close
#      waits (close_space_waits up), the data reads back after a remount.
#   E. W's wait, ended instead by shutdown=now -- the documented way out
#      when no space can be found: the write fails, the mount stops.
#   B. W's wait with space_wait_secs=3 and the block never given room:
#      past the budget the write fails and the mount stops -- the wait
#      was unbounded, its waiter unkillable, and peers waited on it for as
#      long as the pool stayed full (audit 2026-11-22, N-34 / C-1).
#   D. C's close with the refusals never ending and space_wait_secs=3:
#      the close returns and the mount stops (N-48). Control for both:
#      space_wait_secs=0, the old unbounded wait -- still waiting at 8 s.
# fsck clean after each.
#
# DISCRIMINATION: space_wait_stops=1 -- W and H stop the mount, as
# before; close_space_wait_off=1 -- C drops the writes (zeros).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
SBPOKE="$(ct_helper sb_poke)"
IMG="$(ct_image 560 thinow)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt thinow)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
for k in meta_write_nospc_block new_block_nospc space_wait_stops close_space_wait_off test_hold_record_ino; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set meta_write_nospc_block 0
ct_param_set new_block_nospc 0
ct_param_set space_wait_stops 0
ct_param_set close_space_wait_off 0
ct_param_set test_hold_record_ino 0
ct_param_set space_wait_secs 300
ct_param_set hb_interval_secs 2
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
fresh() {
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
}
rec_lba() { echo $(($("$SBPOKE" "$DEV" | sed -n 's/^inode_table_start=//p') + $1 - 1)); }
finish() { # -> " stopped=<cause> fsck=<ok|bad>"
    local st
    st="$(info stopped)"
    echo 0 >$P/meta_write_nospc_block
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    ct_fsck "$DEV" >/dev/null 2>&1 && echo " stopped=${st:-none} fsck=ok" || echo " stopped=${st:-none} fsck=bad"
}

# <stops 0|1> -> RES
case_w() {
    local lba w0 pid alive
    fresh
    echo x >"$MNT/f"
    sync
    lba="$(rec_lba "$(stat -c %i "$MNT/f")")"
    w0="$(info space_waits)"
    echo "$1" >$P/space_wait_stops
    echo "$lba" >$P/meta_write_nospc_block
    chmod 600 "$MNT/f" 2>/dev/null &
    pid=$!
    sleep 3
    kill -0 "$pid" 2>/dev/null && alive=yes || alive=no
    RES="waiting=$alive waits=$(($(info space_waits) - w0)) midstop=$(info stopped | tr ' ' _)"
    echo 0 >$P/meta_write_nospc_block
    wait "$pid" && RES="$RES chmod=ok" || RES="$RES chmod=fail"
    echo 0 >$P/space_wait_stops
    RES="$RES mode=$(stat -c %a "$MNT/f" 2>/dev/null)$(finish)"
}

# The way out when space cannot be found: a stop ends the wait.
case_e() {
    local lba pid t0 i
    fresh
    echo x >"$MNT/f"
    sync
    lba="$(rec_lba "$(stat -c %i "$MNT/f")")"
    echo "$lba" >$P/meta_write_nospc_block
    chmod 600 "$MNT/f" 2>/dev/null &
    pid=$!
    sleep 2
    echo shutdown=now >"$(ct_procdir "$DEV")/controls"
    t0=$SECONDS
    for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && RES="ended=no" || RES="ended=yes secs=$((SECONDS - t0))"
    wait "$pid" 2>/dev/null && RES="$RES chmod=ok" || RES="$RES chmod=fail"
    RES="$RES$(finish)"
}

# <budget secs> -> RES: a refused overwrite that never gets room
case_b() {
    local lba pid i
    fresh
    echo x >"$MNT/f"
    sync
    lba="$(rec_lba "$(stat -c %i "$MNT/f")")"
    echo "$1" >$P/space_wait_secs
    echo "$lba" >$P/meta_write_nospc_block
    chmod 600 "$MNT/f" 2>/dev/null &
    pid=$!
    for i in $(seq 1 16); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && RES="ended=no" || RES="ended=yes"
    RES="$RES midstop=$(info stopped | tr ' ' _)"
    echo 0 >$P/meta_write_nospc_block
    wait "$pid" 2>/dev/null && RES="$RES chmod=ok" || RES="$RES chmod=fail"
    echo 300 >$P/space_wait_secs
    RES="$RES$(finish)"
}

# <budget secs> -> RES: a last close whose map never gets room
case_d() {
    local pid i
    fresh
    fallocate -l 4M "$MNT/c"
    sync
    echo "$1" >$P/space_wait_secs
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
for i in range(1, 62, 2):
    os.pwrite(fd, b"block-%04d" % i, i * 4096)
open(sys.argv[2], "w").write("1000000")
try:
    os.close(fd)
except OSError:
    pass
' "$MNT/c" "$P/new_block_nospc" &
    pid=$!
    for i in $(seq 1 16); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && RES="ended=no" || RES="ended=yes"
    RES="$RES midstop=$(info stopped | tr ' ' _)"
    echo 0 >$P/new_block_nospc
    wait "$pid" 2>/dev/null || true
    echo 300 >$P/space_wait_secs
    RES="$RES$(finish)"
}

# The record is held by TEST ONLY test_hold_record_ino at the next
# heartbeat maintenance pass, just before that pass's held flush.
case_h() {
    local ino h0 i
    fresh
    echo x >"$MNT/g"
    sync
    ino="$(stat -c %i "$MNT/g")"
    h0="$(info held_refusals)"
    echo "$1" >$P/space_wait_stops
    echo "$(rec_lba "$ino")" >$P/meta_write_nospc_block
    echo "$ino" >$P/test_hold_record_ino
    for i in $(seq 1 30); do
        [ "$(($(info held_refusals) - h0))" -ge 1 ] && break
        [ "$(info stopped)" != none ] && break
        sleep 0.5
    done
    sleep 3 # more flushes, still refused
    RES="held=$(($(info held_refusals) - h0)) listed=$(info held_listed) midstop=$(info stopped | tr ' ' _)"
    echo 0 >$P/meta_write_nospc_block
    echo 0 >$P/space_wait_stops
    wait_for 15 "[ \"\$(sed -n 's/^held_listed: //p' '$(ct_procdir "$DEV")/info')\" = 0 ]" || true
    RES="$RES after=$(info held_listed)$(finish)"
}

case_c() {
    local c0 bad=0
    fresh
    fallocate -l 4M "$MNT/c"
    sync
    c0="$(info close_space_waits)"
    echo "$1" >$P/close_space_wait_off
    # One writer, one close: the injection lands between the writes and
    # the close that converts them (each dd's own close would convert its
    # write first).
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
for i in range(1, 62, 2):
    os.pwrite(fd, b"block-%04d" % i, i * 4096)
open(sys.argv[2], "w").write("40")
try:
    os.close(fd)
except OSError:
    pass
' "$MNT/c" "$P/new_block_nospc"
    RES="cwaits=$(($(info close_space_waits) - c0)) left=$(cat $P/new_block_nospc)"
    echo 0 >$P/new_block_nospc
    echo 0 >$P/close_space_wait_off
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    for i in $(seq 1 2 61); do
        [ "$(dd if="$MNT/c" bs=4096 skip="$i" count=1 status=none | head -c 10 | tr -d "\\0")" = "$(printf 'block-%04d' "$i")" ] ||
            bad=$((bad + 1))
    done
    RES="$RES lost=$bad$(finish)"
}

case_w 0
W="$RES"
log "W fixed: $W"
case_w 1
WC="$RES"
log "W control: $WC"
case_e
E="$RES"
log "E (shutdown while waiting): $E"
case_b 3
B="$RES"
log "B (budget 3 s): $B"
case_b 0
BC="$RES"
log "B control (no budget): $BC"
case_d 3
D="$RES"
log "D (budget 3 s): $D"
case_d 0
DC="$RES"
log "D control (no budget): $DC"
case_h 0
H="$RES"
log "H fixed: $H"
case_h 1
HC="$RES"
log "H control: $HC"
case_c 0
C="$RES"
log "C fixed: $C"
case_c 1
CC="$RES"
log "C control: $CC"

[ "$(field waiting "$W")" = yes ] && [ "$(field waits "$W")" -ge 1 ] && [ "$(field midstop "$W")" = none ] &&
    pass "W: the refused overwrite waited, the mount kept running" || fail "W: $W"
[ "$(field chmod "$W")" = ok ] && [ "$(field mode "$W")" = 600 ] && [ "$(field stopped "$W")" = none ] &&
    [ "$(field fsck "$W")" = ok ] && pass "W: with room again it completed; mode on the device, fsck clean" ||
    fail "W: $W"
[ "$(field midstop "$WC")" != none ] && pass "W control: as before, the refusal stopped the mount" ||
    fail "W control: the refusal did not reach the overwrite -- $WC"
[ "$(field ended "$E")" = yes ] && [ "$(field chmod "$E")" = fail ] && [ "$(field stopped "$E")" = manual ] &&
    pass "E: shutdown=now ended a write waiting for space ($(field secs "$E") s); the mount stopped" || fail "E: $E"
[ "$(field ended "$B")" = yes ] && [ "$(field chmod "$B")" = fail ] && [ "$(field midstop "$B")" != none ] &&
    pass "B: past the budget the refused overwrite failed and the mount stopped ($B)" || fail "B: $B"
[ "$(field ended "$BC")" = no ] && [ "$(field midstop "$BC")" = none ] &&
    pass "B control: with no budget it was still waiting at 8 s, the mount up" ||
    fail "B control: the wait ended without a budget -- the check cannot tell: $BC"
[ "$(field ended "$D")" = yes ] && [ "$(field midstop "$D")" != none ] &&
    pass "D: past the budget the last close returned and the mount stopped ($D)" || fail "D: $D"
[ "$(field ended "$DC")" = no ] && [ "$(field midstop "$DC")" = none ] &&
    pass "D control: with no budget the close was still waiting at 8 s" ||
    fail "D control: the close did not wait -- the refusals do not reach it: $DC"
[ "$(field held "$H")" -ge 1 ] && [ "$(field midstop "$H")" = none ] && [ "$(field stopped "$H")" = none ] &&
    [ "$(field after "$H")" = 0 ] && [ "$(field fsck "$H")" = ok ] && pass "H: a refused held block was kept for the next flush; fsck clean" ||
    fail "H: $H"
[ "$(field midstop "$HC")" != none ] && pass "H control: as before, the held refusal stopped the mount" ||
    fail "H control: the refusal did not reach the held flush -- $HC"
[ "$(field cwaits "$C")" -ge 1 ] && [ "$(field lost "$C")" = 0 ] && [ "$(field fsck "$C")" = ok ] &&
    pass "C: the last close waited for space; every written block reads back, fsck clean" || fail "C: $C"
[ "$(field lost "$CC")" -gt 0 ] && pass "C control: without the wait the close dropped the writes ($(field lost "$CC") lost)" ||
    fail "C control: the refusals did not reach the last close -- $CC"
ct_exit
