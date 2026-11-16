#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a local close() does not wait behind another open's fence and replay
#
# An open that finds a dead node's lock on the file fences that node and
# replays its journal before taking the lock -- device I/O of unbounded
# length, which the code itself put at minutes. It did all of that under
# the inode's lock_mutex, and close() takes that mutex plainly (a release
# cannot fail): every local close of the same file waited, uninterruptibly,
# behind it (audit 2026-11-15 M-27, BM-38). The open now drops the mutex
# across the fence, the replay, the silence watch and the yield wait, and
# decides again from a fresh read once it has it back.
#
# A reader holds v open. Row 1, stale, holds v's lock. A write-open of v
# fences row 1 and is held for 8 s right after the fence (a test stall);
# meanwhile the reader closes:
#   fixed:   the close returns at once, and the write-open still succeeds;
#   control: lock_open_slow_held=1 -- the close waits out the stall.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 clrep)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt clrep)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set lock_open_slow_held 0
ct_param_set reclaim_stall_after_fence_ms 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

ct_mkfs "$DEV" -z 1 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
echo hb_interval_secs=5 >"$CTL"
echo stale_secs=15 >"$CTL"

# <tag> <slow_held 0|1> <row> -> RES
round() {
    local f="$MNT/v$1" go out wout pid wpid
    go="$(ct_tmp "clrep-go-$1")" out="$(ct_tmp "clrep-out-$1")" wout="$(ct_tmp "clrep-w-$1")"
    rm -f "$go"
    echo data >"$f"
    sync
    python3 -c 'import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
open(sys.argv[3], "w").write("opened\n")
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
t = time.time(); os.close(fd)
open(sys.argv[3], "w").write("close=%.1f\n" % (time.time() - t))' "$f" "$go" "$out" &
    pid=$!
    wait_for 10 "grep -q opened '$out'" || { fail "setup: the reader never opened"; ct_exit; }
    poke_dead_peer "$DEV" "$3" "c$3"
    "$NPOKE" "$DEV" "$3" --stale 15 >/dev/null
    "$LPOKE" "$DEV" "$(stat -c %i "$f")" "$3" 1 >/dev/null
    wait_for 60 "grep -q '^node $3: .*stale=yes' '$(ct_procdir "$DEV")/cluster'" ||
        { fail "setup: row $3 never went stale"; ct_exit; }
    echo "$2" >/sys/module/cetrafs/parameters/lock_open_slow_held
    echo 8000 >/sys/module/cetrafs/parameters/reclaim_stall_after_fence_ms
    python3 -c 'import os, sys
try:
    os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND)); print("wopen=ok")
except OSError as e:
    print("wopen=%d" % e.errno)' "$f" >"$wout" 2>&1 &
    wpid=$!
    sleep 2 # the write-open is in the stall, past the fence
    : >"$go"
    wait "$pid" || true
    wait "$wpid" || true
    echo 0 >/sys/module/cetrafs/parameters/lock_open_slow_held
    echo 0 >/sys/module/cetrafs/parameters/reclaim_stall_after_fence_ms
    RES="$(cat "$out") $(cat "$wout")"
}

round f 0 1
F="$RES"
log "fixed: $F"
round c 1 2
C="$RES"
log "control (mutex held across): $C"

awk -v c="$(field close "$F")" 'BEGIN { exit !(c != "" && c < 2) }' &&
    pass "fixed: the close returned at once while the open was in its fence ($F)" || fail "fixed: $F"
[ "$(field wopen "$F")" = ok ] && pass "fixed: and the write-open still took the stale lock" ||
    fail "fixed: the write-open failed: $F"
awk -v c="$(field close "$C")" 'BEGIN { exit !(c != "" && c >= 4) }' &&
    pass "control: as before, the close waited behind the stall ($C)" ||
    fail "control: the close did not wait -- the suite does not reach the mutex: $C"
ct_umount "$MNT"
ct_exit
