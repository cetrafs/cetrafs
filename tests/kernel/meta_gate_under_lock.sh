#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a metadata write that waited for its buffer lock across a fence is not sent
#
# Every metadata writer asked "am I fenced?" and then took
# lock_buffer(), which waits out a write of the same block already in
# flight -- for as long as the device takes. A node whose lease was
# revoked during that wait submitted its newer image anyway, after a
# peer may have taken the block over (audit 2026-11-15 BM-24). The fence
# is now asked again under the buffer lock, at every submission.
#
# A create's write of its directory's entry block is held just after it locks its
# buffer (meta_gate_stall_ms, which logs the block); during the hold a
# peer revokes this node's lease (its fence epoch bumped on the device)
# and the node self-fences; then the write goes on:
#   1. the block on the device is what it was when the write was held;
#   2. the mount did not call it a device error.
#
# DISCRIMINATION: meta_gate_unlocked_only=1 (the fence asked only before
# the lock, as before): the block changes after the fence.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in meta_gate_stall_ms meta_gate_stall_block meta_gate_unlocked_only; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt mgl)"
ct_track mnt "$MNT"
ct_param_set meta_gate_stall_ms 0
ct_param_set meta_gate_unlocked_only 0
ct_param_set meta_gate_stall_block 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
# the fenced mount leaves a row that reads mounted
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# the journal's debug line has no newline: a message after it closes it
first_target() {
    dmesg_mark >/dev/null
    dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1 || true
}
h() { dd if="$1" bs=4096 skip="$2" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }

# <tag> <unlocked_only 0|1> -> RES
round() {
    local img dev mark blk before after pid
    img="$(ct_image 560 "mgl$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    mark="$(dmesg_mark)"
    touch "$MNT/d/a"
    blk="$(first_target "$mark")"
    [ -n "$blk" ] || { fail "setup: no journal target logged for the directory's entry block"; ct_exit; }
    sync
    echo "$2" >$P/meta_gate_unlocked_only
    mark="$(dmesg_mark)"
    echo "$blk" >$P/meta_gate_stall_block
    echo 8000 >$P/meta_gate_stall_ms
    touch "$MNT/d/f" 2>/dev/null &
    pid=$!
    for _ in $(seq 1 100); do
        dmesg_since "$mark" | grep -q "meta_gate_stall: block $blk," && break
        sleep 0.05
    done
    dmesg_since "$mark" | grep -q "meta_gate_stall: block $blk," ||
        { fail "setup: the create's entry-block write never reached the stall"; ct_exit; }
    before="$(h "$dev" "$blk")"
    "$NODE_POKE" "$dev" 0 --bump-fence 1 >/dev/null
    # The self-fence's sweep queues behind the held buffer, so its message
    # comes after the hold: wait for both, then ask that it happened.
    wait "$pid" 2>/dev/null || true
    wait_for 10 "dmesg_since '$mark' | grep -q SELF-FENCED" ||
        { fail "setup: the node did not self-fence"; ct_exit; }
    sleep 0.5
    after="$(h "$dev" "$blk")"
    echo 0 >$P/meta_gate_unlocked_only
    echo 0 >$P/meta_gate_stall_block
    RES="blk=$blk same=$([ "$before" = "$after" ] && echo 1 || echo 0)"
    RES="$RES device_err=$(dmesg_since "$mark" | grep -c 'refused a metadata write' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (fence asked before the lock only): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get same "$R")" = 1 ] && pass "1: the held write was not sent after the fence -- block $(get blk "$R") unchanged" ||
    fail "1: the write landed after the fence: $R"
[ "$(get device_err "$R")" = 0 ] && pass "2: the refusal was not reported as a device error" || fail "2: $R"
[ "$(get same "$C")" = 0 ] && pass "control: asked only before the lock, the write landed after the fence" ||
    fail "control: the block did not change without the fix -- the held write changes nothing: $C"
ct_exit
