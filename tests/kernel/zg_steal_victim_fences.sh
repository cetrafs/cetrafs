#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node whose Zone Group was taken stops allocating by its next heartbeat tick
#
# The allocator trusts this node's CACHED Zone Group ownership on every
# block (a device read per block would cost a round trip each), and the
# tree said that was safe because "ownership cannot change while the
# node is alive". It can: a peer that judged this node stale -- rightly
# or not -- takes the ZG, bumping this node's fence_epoch first. What
# bounds the damage is the lease: this node sees the epoch move on its
# next heartbeat tick and fences, refusing every write after it (audit
# R24). This is the assertion the comment now cites.
#
# The steal is poked on the device exactly as a peer's reclaim leaves
# it: ZG 0 owned by registry row 1, this node's fence_epoch bumped.
# A writer allocates continuously; within two ticks every write fails.
#
# DISCRIMINATION: with the epoch left alone (only the owner changed), the
# writer keeps allocating -- which is why the epoch bump is part of every
# reclaim, and why this suite pokes both.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
ZPOKE="$(ct_helper zg_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 zgsteal)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgsteal)"
ct_mkfs_small "$DEV" -M 2 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 2))
dd if=/dev/zero of="$MNT/warm" bs=4096 count=4 conv=fsync status=none ||
    { fail "setup: cannot write before the steal"; ct_exit; }

# writes_fail_within <secs>: append a block per 0.2 s, each to a new
# file (so each needs an allocation); print the seconds until the first
# failure, or "never".
writes_fail_within() {
    local t0 i=0 now
    t0="$(date +%s.%N)"
    while :; do
        if ! dd if=/dev/zero of="$MNT/w$i" bs=4096 count=1 conv=fsync status=none 2>/dev/null; then
            now="$(date +%s.%N)"
            awk -v a="$t0" -v b="$now" 'BEGIN { printf "%.1f\n", b - a }'
            return
        fi
        i=$((i + 1))
        now="$(date +%s.%N)"
        awk -v a="$t0" -v b="$now" -v l="$1" 'BEGIN { exit !(b - a > l) }' && { echo never; return; }
        sleep 0.2
    done
}

# The control: only the owner moves, the epoch does not. Nothing tells
# this node, so it keeps allocating from its cache for the whole wait.
"$ZPOKE" "$IMG" 0 "$PEER" >/dev/null
T="$(writes_fail_within 6)"
[ "$T" = never ] && pass "control: with the owner changed but no epoch bump, writes go on (the cache is all it has)" ||
    fail "control: writes failed after ${T}s with no epoch bump -- something else stopped them, the suite proves nothing"

# The real steal: owner AND epoch, as every reclaim does.
"$NPOKE" "$IMG" "$NID" --bump-fence 1 >/dev/null
T="$(writes_fail_within 8)"
log "first refused write ${T}s after the steal (heartbeat interval 2s)"
[ "$T" != never ] && awk -v t="$T" 'BEGIN { exit !(t <= 4.5) }' &&
    pass "the victim stopped allocating ${T}s after the steal -- within two ticks" ||
    fail "the victim was still allocating ${T}s after its ZG was taken and its lease revoked"
grep -q "fenced: yes" "$(ct_procdir "$DEV")/info" && pass "and it is fenced" ||
    fail "writes stopped but the mount is not fenced"

umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
ct_exit
