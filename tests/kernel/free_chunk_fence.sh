#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a direct free that a fence lands in stops clearing bits at its next chunk
#
# Freeing a large extent lets go of alloc_mutex every 4096 blocks so
# allocations are not stalled behind it. After each let-go the pending-
# free apply asks again whether this node is fenced and still owns the
# group; the direct free asked nothing, and went on clearing bits of a
# bitmap that a peer may own by then (audit 2026-11-14 M-2).
#
# A 64 MiB preallocated file is removed; its free is held at the first
# chunk boundary (free_chunk_stall_ms); during the hold this node's
# lease is revoked on the device and it self-fences:
#   1. the free stops there: "failed after 4096 block(s): -5" -- the
#      rest of the extent's bits stay set, for the scrub.
#
# DISCRIMINATION: free_chunk_recheck_off=1 (nothing asked after the
# let-go, as before): the free runs to the end, no failure reported.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in free_chunk_stall_ms free_chunk_recheck_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
command -v fallocate >/dev/null || { skip "no fallocate(1)"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt fcf)"
ct_track mnt "$MNT"
ct_param_set free_chunk_stall_ms 0
ct_param_set free_chunk_recheck_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <recheck_off 0|1> -> RES
round() {
    local img dev mark pid
    img="$(ct_image 560 "fcf$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    fallocate -l 64M "$MNT/big"
    sync
    echo "$2" >$P/free_chunk_recheck_off
    mark="$(dmesg_mark)"
    echo 5000 >$P/free_chunk_stall_ms
    rm -f "$MNT/big" &
    pid=$!
    for _ in $(seq 1 100); do
        dmesg_since "$mark" | grep -q "free: chunk stall" && break
        sleep 0.05
    done
    dmesg_since "$mark" | grep -q "free: chunk stall" ||
        { fail "setup: the free never reached a chunk boundary -- no extent of 4096+ blocks"; ct_exit; }
    "$NODE_POKE" "$dev" 0 --bump-fence 1 >/dev/null
    wait_for 5 "dmesg_since '$mark' | grep -q SELF-FENCED" || { fail "setup: the node did not self-fence"; ct_exit; }
    wait "$pid" 2>/dev/null || true
    echo 0 >$P/free_chunk_recheck_off
    echo 0 >$P/free_chunk_stall_ms
    RES="stopped=$(dmesg_since "$mark" | grep -c 'failed after 4096 block(s): -5' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (nothing asked after the let-go): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get stopped "$R")" -ge 1 ] && pass "1: the fenced free stopped at the chunk boundary" || fail "1: $R"
[ "$(get stopped "$C")" = 0 ] && pass "control: asking nothing, the free ran on past the fence" ||
    fail "control: the free stopped without the recheck -- something else stops it: $C"
ct_exit
