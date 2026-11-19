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
# B. The same takeover AFTER that check (audit F-71): the check read
# the claim ours, the record CAS, the flush and the number free followed,
# and a peer's steal judged from the old incarnation could land among
# them. The claim is now made this incarnation's before the check
# (CETRAFS_RECLAIM_ADOPT), which moves the stamp and the incarnation a
# steal judged from. Staged as A, held after the check instead
# (forget_tree_stall_ms); in the pause the steal lands only as a peer's
# CAS would: while the claim still carries the incarnation judged stale.
#   setup B: forget_tree paused after its check;
#   4. the steal was refused, and the sweep finished its own free;
#   5. the claim is not node 3's.
#
# DISCRIMINATION: forget_tree_any_owner=1 -- A: the sweep frees the
# number under node 3's claim; B: the steal lands in the window and the
# number is freed under node 3's claim.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in sweep_judge_stall_ms forget_tree_any_owner forget_tree_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
ORPHAN_POKE="$(ct_helper orphan_poke)"
MNT="$(ct_mnt swsteal)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set stale_secs 8 # the re-attach watches its row this long, not 120 s
ct_param_set scrub 0 # the orphan scrub would free the planted number on its own
ct_param_set auto_defrag 0
ct_param_set sweep_judge_stall_ms 0
ct_param_set forget_tree_any_owner 0
ct_param_set forget_tree_stall_ms 0
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

nsinc() { "$LOCK_POKE" "$1" "$PINO" --incs | sed -n 's/.*ns_inc=\([0-9]*\).*/\1/p'; }
# <any_owner 0|1> -> "paused= stolen= allocated= owner="
round_b() {
    local img dev nid mark pid paused=0 stolen=0 alloc=0 owner judged o
    img="$(ct_image 560 "swstealb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    nid="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    "$ORPHAN_POKE" "$dev" "$PINO" 0 0 >/dev/null
    "$LOCK_POKE" "$dev" "$PINO" --ns "$nid" >/dev/null
    "$NODE_POKE" "$dev" "$nid" --beat >/dev/null
    blockdev --flushbufs "$dev"
    judged="$(nsinc "$dev")" # the incarnation a peer judges stale
    echo "$1" >/sys/module/cetrafs/parameters/forget_tree_any_owner
    echo 4000 >/sys/module/cetrafs/parameters/forget_tree_stall_ms
    mark="$(dmesg_mark)"
    mount -t cetrafs "$dev" "$MNT" &
    pid=$!
    for _ in $(seq 1 1000); do
        dmesg_since "$mark" | grep -q "forget_tree: ino=$PINO: pausing" && { paused=1; break; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if [ "$paused" = 1 ]; then
        # Read straight from the image: a flushbufs on the device would
        # wait for the mount, and so read after the window.
        [ "$(nsinc "$img")" = "$judged" ] && "$LOCK_POKE" "$img" "$PINO" --ns "$PEER" >/dev/null && stolen=1
    fi
    wait "$pid" || true
    echo 0 >/sys/module/cetrafs/parameters/forget_tree_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/forget_tree_any_owner
    findmnt "$MNT" >/dev/null && ct_umount "$MNT"
    o="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q "inode $PINO is allocated" <<<"$o" && alloc=1
    owner="$("$LOCK_POKE" "$dev" "$PINO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')"
    echo "paused=$paused stolen=$stolen allocated=$alloc owner=$owner"
}
R="$(round_b 0)"
log "adopted: $R"
C="$(round_b 1)"
log "control (not adopted): $C"
for v in "$R" "$C"; do
    [ "$(get paused "$v")" = 1 ] || { fail "setup B: forget_tree never paused on ino $PINO ($v)"; ct_exit; }
done
pass "setup B: forget_tree paused after its check on ino $PINO"
[ "$(get stolen "$R")" = 0 ] && [ "$(get allocated "$R")" = 0 ] &&
    pass "4: the steal was refused, and the sweep finished its own free" ||
    fail "4: the steal landed or the free was not finished ($R)"
[ "$(get owner "$R")" != "$PEER" ] && pass "5: the claim is not node $PEER's" || fail "5: the claim is node $PEER's ($R)"
[ "$(get stolen "$C")" = 1 ] && [ "$(get allocated "$C")" = 0 ] &&
    pass "control: not adopted, the steal landed in the window and the number was freed under it" ||
    fail "control: no steal and free in the window -- the suite does not reach it ($C)"
ct_exit
