#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a blocking nofilelock flock waits for a peer opener without claiming and giving back the lock
#
# Under nofilelock a blocking flock(LOCK_EX) on a file a peer has open
# claimed the lock by compare-and-swap, found the peer, swapped it back
# -- and did it again ten times a second: ~20 device writes a second
# per waiter, and every peer open landing inside one of those windows
# refused ETXTBSY for a lock that was never going to stand (audit
# 2026-11-14 M-26). It now asks, read-only, whether a peer has the file
# open before claiming, and backs off while one does.
#
# A live node 1 (beating) has the file open; a blocking flock waits 5 s:
#   1. it does not get the lock, and it never claimed and gave it back;
#   2. node 1 closes: the next flock takes the lock at once.
#
# DISCRIMINATION: flock_no_precheck=1 (claim first, poll at a fixed
# 100 ms): dozens of claims given back within the 5 s.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/flock_no_precheck ] || { skip "flock_no_precheck is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt fwq)"
ct_track mnt "$MNT"
ct_param_set flock_no_precheck 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <no_precheck 0|1> -> RES
round() {
    local dev ino beater proc b0 b1 got=0 after=0
    dev="$(ct_dev 560 "fwq$1")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    echo image >"$MNT/vm.img"
    ino="$(stat -c %i "$MNT/vm.img")"
    sync
    exec 9>>"$MNT/vm.img"
    "$NODE_POKE" "$dev" 1 1 bb "$(date +%s)" >/dev/null
    (for _ in $(seq 1 60); do "$NODE_POKE" "$dev" 1 --beat >/dev/null 2>&1; sleep 0.25; done) 9>&- &
    beater=$!
    "$LOCK_POKE" "$dev" "$ino" --reader 1 >/dev/null
    echo "$2" >$P/flock_no_precheck
    b0="$(sed -n 's/^flock_backouts: //p' "$proc/info")"
    flock -x -w 5 9 && got=1
    b1="$(sed -n 's/^flock_backouts: //p' "$proc/info")"
    echo 0 >$P/flock_no_precheck
    "$LOCK_POKE" "$dev" "$ino" --unreader 1 >/dev/null
    flock -x -w 3 9 && after=1
    [ "$after" = 1 ] && flock -u 9
    exec 9>&-
    kill "$beater" 2>/dev/null || true
    wait "$beater" 2>/dev/null || true
    "$NODE_POKE" "$dev" 1 0 bb 0 >/dev/null
    ct_umount "$MNT"
    RES="got=$got backouts=$((b1 - b0)) after=$after"
}

round c 1
C="$RES"
log "control (claim first): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get got "$R")" = 0 ] && [ "$(get backouts "$R")" = 0 ] &&
    pass "1: the waiter did not take the open file, and never claimed and gave back its lock" || fail "1: $R"
[ "$(get after "$R")" = 1 ] && pass "2: the peer closed; the next flock took the lock" || fail "2: $R"
[ "$(get got "$C")" = 0 ] && [ "$(get backouts "$C")" -ge 10 ] &&
    pass "control: claiming first gave the lock back $(get backouts "$C") times in 5 s" ||
    fail "control: $C -- the suite does not see the claims"
ct_exit
