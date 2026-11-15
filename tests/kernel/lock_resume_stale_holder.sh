#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a default-mount resume takes back the lock of a holder that died, never of one that is alive
#
# A migration source suspends its automatic lock (flock LOCK_UN), the
# destination claims the file -- and dies. The source's resume (flock
# LOCK_EX) answered ETXTBSY whenever the lock was held, with no question
# of who held it: nothing ever released the dead holder's claim, and the
# source's VM writes failed until qemu was restarted. The nofilelock
# flock reclaimed a dead holder; the resume did not (audit 2026-11-14
# M-25). It now fences the dead holder, replays its journal and displaces
# exactly its claim.
#
#   1. a live holder (beating) keeps its lock: the resume waits;
#   2. the holder stops beating: the waiting resume takes the lock, which
#      is then this node's, and says so.
#
# DISCRIMINATION: lock_resume_no_reclaim=1: 2's resume times out.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the default mount's LOCK_UN suspend and LOCK_EX resume"
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/lock_resume_no_reclaim ] || { skip "lock_resume_no_reclaim is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt lrsh)"
ct_track mnt "$MNT"
ct_param_set lock_resume_no_reclaim 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <no_reclaim 0|1> -> RES
round() {
    local dev ino beater live=0 took=0 mark nid owner
    dev="$(ct_dev 560 "lrsh$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo image >"$MNT/vm.img"
    ino="$(stat -c %i "$MNT/vm.img")"
    sync
    exec 9>>"$MNT/vm.img"
    flock -u 9
    echo "$2" >$P/lock_resume_no_reclaim
    # the destination: alive, and it takes the file
    "$NODE_POKE" "$dev" 1 1 bb "$(date +%s)" >/dev/null
    "$LOCK_POKE" "$dev" "$ino" 1 1 >/dev/null
    (for _ in $(seq 1 40); do "$NODE_POKE" "$dev" 1 --beat >/dev/null 2>&1; sleep 0.25; done) 9>&- &
    beater=$!
    flock -x -w 6 9 && live=1
    kill "$beater" 2>/dev/null || true
    wait "$beater" 2>/dev/null || true
    # it dies: no more beats
    mark="$(dmesg_mark)"
    flock -x -w $((TEST_STALE_SECS + 20)) 9 && took=1
    nid="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$dev")/info")"
    owner="$("$LOCK_POKE" "$dev" "$ino" | grep -o '\bowner=[0-9]*' | head -1 | cut -d= -f2)"
    echo 0 >$P/lock_resume_no_reclaim
    RES="live_taken=$live took=$took owner=$owner me=$nid"
    RES="$RES logged=$(dmesg_since "$mark" | grep -c 'resume: ino=.* reclaiming a stale lock from node 1' || true)"
    [ "$took" = 1 ] && flock -u 9
    exec 9>&-
    "$NODE_POKE" "$dev" 1 0 bb 0 >/dev/null
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (no reclaim): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get live_taken "$R")" = 0 ] && [ "$(get live_taken "$C")" = 0 ] &&
    pass "1: a beating holder kept its lock; the resume waited" || fail "1: a live holder's lock was taken ($R | $C)"
[ "$(get took "$R")" = 1 ] && [ "$(get owner "$R")" = "$(get me "$R")" ] && [ "$(get logged "$R")" -ge 1 ] &&
    pass "2: the holder died; the resume took its lock back and said so" || fail "2: $R"
[ "$(get took "$C")" = 0 ] &&
    pass "control: without the reclaim the resume timed out against the dead holder" ||
    fail "control: the resume took the lock without the reclaim ($C) -- the suite does not reach it"
ct_exit
