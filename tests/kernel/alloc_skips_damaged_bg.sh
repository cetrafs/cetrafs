#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a damaged owned Block Group descriptor is passed over by the allocator, not the end of every write
#
# The allocator's scan of the Block Groups this node owns stopped at the
# first one whose descriptor would not verify, and returned that error:
# once its cursor group was unusable, every allocation of the node failed
# with every other owned group free (audit 2026-11-15 BM-6). A damaged
# descriptor (-EUCLEAN, after every retry) is now passed over and
# counted; fsck.cetra -r rebuilds it.
#
# One Zone Group of two Block Groups, both ours. Under the mount, Block
# Group 0's descriptor is damaged on the device (one bit of its pad, the
# checksum left alone) and the cached copy dropped; then a file is
# written:
#   1. the write succeeds, from Block Group 1;
#   2. the skip is counted, and the damage is recorded (corruptions);
#   3. the mount runs on.
#
# DISCRIMINATION: alloc_damaged_aborts=1 (as before): the write fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/alloc_damaged_aborts ] || { skip "alloc_damaged_aborts is missing"; ct_exit; }
POKE="$(ct_helper csum_poke)"
MNT="$(ct_mnt asd)"
ct_track mnt "$MNT"
ct_param_set alloc_damaged_aborts 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <aborts 0|1> -> RES
round() {
    local img dev proc s0 rc=0
    img="$(ct_image 1200 "asd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    s0="$(sed -n 's/^alloc_damaged_skips: //p' "$proc/info")"
    "$POKE" "$img" bg-desc 0 >/dev/null
    blockdev --flushbufs "$dev" 2>/dev/null || true
    sync
    echo 3 >/proc/sys/vm/drop_caches
    echo "$2" >/sys/module/cetrafs/parameters/alloc_damaged_aborts
    dd if=/dev/urandom of="$MNT/f" bs=1M count=2 conv=fsync status=none 2>/dev/null || rc=1
    echo 0 >/sys/module/cetrafs/parameters/alloc_damaged_aborts
    RES="write=$([ "$rc" = 0 ] && echo ok || echo fail)"
    RES="$RES skips=$(($(sed -n 's/^alloc_damaged_skips: //p' "$proc/info") - s0))"
    RES="$RES corrupt=$(sed -n 's/^corruptions: //p' "$proc/info")"
    RES="$RES alive=$(stat -c %s "$MNT/f" 2>/dev/null || echo no)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (a damaged group ends the allocation): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get write "$R")" = ok ] && pass "1: the write succeeded past the damaged group" || fail "1: $R"
[ "$(get skips "$R")" -ge 1 ] && [ "$(get corrupt "$R")" -ge 1 ] &&
    pass "2: the skip was counted and the damage recorded" || fail "2: $R"
[ "$(get alive "$R")" = 2097152 ] && pass "3: the mount runs on" || fail "3: $R"
[ "$(get write "$C")" = fail ] && pass "control: with a damaged group ending the allocation, the write failed ($C)" ||
    fail "control: $C -- the damaged descriptor was never read on the allocation path"
ct_exit
