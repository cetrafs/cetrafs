#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a flock steal displaces only the incarnation it judged stale, never one taken again since
#
# flock (and the default mount's resume) take a dead holder's lock by
# fencing it, replaying its journal and swapping its claim away. The
# swap was bound to the incarnation read AFTER the fence and replay: a
# holder that re-attached in that time and took the lock again carried
# a new incarnation, the re-read picked it up, and the swap stole a live
# holder's lock -- two writers on one image (audit 2026-11-15 F-22). It
# is now bound to the incarnation judged before the fence.
#
# nofilelock; node 1 holds the lock (incarnation 5) and has stopped
# beating; a blocking flock judges it stale and is held between its
# replay and its swap (reclaim_stall_before_swap_ms) while node 1 beats
# again and takes the lock again (incarnation 6):
#   1. the flock does not get the lock; node 1 still holds it.
#
# DISCRIMINATION: lock_steal_reread_inc=1: the flock takes the lock.
# The knob turns off the re-check after lock_mutex is retaken too
# (N-21): that re-read refuses a changed incarnation before the swap is
# armed, and with it on the control never reached the window.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
for p in lock_steal_reread_inc reclaim_stall_before_swap_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt lsji)"
ct_track mnt "$MNT"
ct_param_set lock_steal_reread_inc 0
ct_param_set reclaim_stall_before_swap_ms 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <reread 0|1> -> RES
round() {
    local dev ino mark fpid beater="" rc=0 owner
    dev="$(ct_dev 560 "lsji$1")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    echo image >"$MNT/vm.img"
    ino="$(stat -c %i "$MNT/vm.img")"
    sync
    exec 9>>"$MNT/vm.img"
    "$NODE_POKE" "$dev" 1 1 bb "$(date +%s)" >/dev/null
    INODE_LOCK_POKE_INC=5 "$LOCK_POKE" "$dev" "$ino" 1 1 >/dev/null
    echo "$2" >$P/lock_steal_reread_inc
    echo 6000 >$P/reclaim_stall_before_swap_ms
    mark="$(dmesg_mark)"
    flock -x -w $((TEST_STALE_SECS + 30)) 9 &
    fpid=$!
    if wait_for $((TEST_STALE_SECS + 20)) "dmesg_since '$mark' | grep -q 'reclaiming a stale lock from node 1'"; then
        # the re-attach: node 1 beats again and takes the lock again
        (for _ in $(seq 1 200); do "$NODE_POKE" "$dev" 1 --beat >/dev/null 2>&1; sleep 0.25; done) 9>&- &
        beater=$!
        INODE_LOCK_POKE_INC=6 "$LOCK_POKE" "$dev" "$ino" 1 1 >/dev/null
        RES="judged=1"
    else
        RES="judged=0"
    fi
    wait "$fpid" || rc=$?
    owner="$("$LOCK_POKE" "$dev" "$ino" | grep -o '\bowner=[0-9]*' | head -1 | cut -d= -f2)"
    RES="$RES flock_rc=$rc owner=$owner"
    echo 0 >$P/reclaim_stall_before_swap_ms
    echo 0 >$P/lock_steal_reread_inc
    [ "$rc" = 0 ] && flock -u 9
    exec 9>&-
    [ -n "$beater" ] && { kill "$beater" 2>/dev/null || true; wait "$beater" 2>/dev/null || true; }
    "$LOCK_POKE" "$dev" "$ino" 65535 0 >/dev/null
    "$NODE_POKE" "$dev" 1 0 bb 0 >/dev/null
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (bound to the re-read): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get judged "$R")" = 1 ] && [ "$(get judged "$C")" = 1 ] ||
    { fail "setup: the flock never judged node 1 stale ($R | $C)"; ct_exit; }
[ "$(get flock_rc "$R")" != 0 ] && [ "$(get owner "$R")" = 1 ] &&
    pass "1: the re-attached holder kept its lock; the flock did not get it" || fail "1: $R"
[ "$(get flock_rc "$C")" = 0 ] && [ "$(get owner "$C")" != 1 ] &&
    pass "control: bound to the re-read incarnation, the flock stole the live holder's lock" ||
    fail "control: $C -- the suite does not reach the window"
ct_exit
