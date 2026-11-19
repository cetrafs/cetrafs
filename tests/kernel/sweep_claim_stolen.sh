#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount sweep does not finish a free whose claim is no longer this node's
#
# A node back from a crash finishes the frees it had claimed: a dead
# record whose namespace claim is its own row's gets its tree forgotten
# and its number freed (cetrafs_lock_sweep_own_claims()). It judged that
# from the walk's read and acted after a record CAS and a flush; the
# number free is a bare bitmap swap that never looks at the record. A
# peer that took the claim over from the stale incarnation meanwhile
# may have finished the free and given the number to a create -- the
# record still dead, of the same generation, until the create stamps
# it -- and the sweep cleared the create's bit (audit 2026-11-15 BC-49).
# cetrafs_inode_forget_tree()'s fresh read now also requires the claim
# to be ours.
#
# Staged: an allocated, dead record claimed by this node's row, the row
# made to look crashed; the remount's sweep held between judging it and
# acting (sweep_judge_stall_ms), and in that pause the claim is moved to
# node 3 on the backing image, as a peer's steal leaves it.
#   setup: the sweep paused on the record;
#   1. the sweep left it: "no longer its own";
#   2. the number is still allocated;
#   3. the claim is still node 3's.
#
# DISCRIMINATION: forget_tree_any_owner=1 -- the sweep frees the number
# under node 3's claim.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in sweep_judge_stall_ms forget_tree_any_owner; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
ORPHAN_POKE="$(ct_helper orphan_poke)"
MNT="$(ct_mnt swsteal)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set scrub 0 # the orphan scrub would free the planted number on its own
ct_param_set auto_defrag 0
ct_param_set sweep_judge_stall_ms 0
ct_param_set forget_tree_any_owner 0
PINO=200
PEER=3

# <any_owner 0|1> -> "paused= left= allocated= owner="
round() {
    local img dev nid mark pid paused=0 left=0 alloc=0 owner o
    img="$(ct_image 560 "swsteal$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    nid="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    "$ORPHAN_POKE" "$dev" "$PINO" 0 0 >/dev/null
    "$LOCK_POKE" "$dev" "$PINO" --ns "$nid" >/dev/null
    "$NODE_POKE" "$dev" "$nid" --beat >/dev/null
    blockdev --flushbufs "$dev"
    echo "$1" >/sys/module/cetrafs/parameters/forget_tree_any_owner
    echo 4000 >/sys/module/cetrafs/parameters/sweep_judge_stall_ms
    mark="$(dmesg_mark)"
    mount -t cetrafs "$dev" "$MNT" &
    pid=$!
    for _ in $(seq 1 1000); do # the re-attach watches its row first (up to 120 s)
        dmesg_since "$mark" | grep -q "mount: ino=$PINO: pausing" && { paused=1; break; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    # The peer's steal: the claim is node PEER's now.
    [ "$paused" = 1 ] && "$LOCK_POKE" "$img" "$PINO" --ns "$PEER" >/dev/null
    wait "$pid" || true
    echo 0 >/sys/module/cetrafs/parameters/sweep_judge_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/forget_tree_any_owner
    dmesg_since "$mark" | grep -q "mount: ino=$PINO: the free this node claimed is no longer its own" && left=1
    findmnt "$MNT" >/dev/null && ct_umount "$MNT"
    o="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q "inode $PINO is allocated but has nlink=0" <<<"$o" && alloc=1
    owner="$("$LOCK_POKE" "$dev" "$PINO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')"
    echo "paused=$paused left=$left allocated=$alloc owner=$owner"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "checked: $R"
C="$(round 1)"
log "control (any owner): $C"
for v in "$R" "$C"; do
    [ "$(get paused "$v")" = 1 ] || { fail "setup: the sweep never paused on ino $PINO ($v)"; ct_exit; }
done
pass "setup: the sweep paused between judging ino $PINO and finishing its free"
[ "$(get left "$R")" = 1 ] && pass "1: the sweep left it: the claim is no longer its own" || fail "1: no 'no longer its own' ($R)"
[ "$(get allocated "$R")" = 1 ] && pass "2: the number is still allocated" ||
    fail "2: the sweep freed a number under another node's claim ($R)"
[ "$(get owner "$R")" = "$PEER" ] && pass "3: the claim is still node $PEER's" || fail "3: the claim moved ($R)"
[ "$(get allocated "$C")" = 0 ] &&
    pass "control: without the check, the sweep freed the number under node $PEER's claim" ||
    fail "control: the number stayed allocated anyway -- the suite does not reach the window ($C)"
ct_exit
