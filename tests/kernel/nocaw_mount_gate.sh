#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# No-CAW mount gate: a live foreign peer is refused BEFORE registering
#
# A device with no atomic CAW has no cross-node mutual exclusion, so only one
# node may mount it. The gate that enforces this used to run AFTER the mount
# registered its own Node Registry row -- so a second node would claim a row
# (visible to the live peer), wait out a staleness window, and only then fail.
# That writes to a shared volume the node is not allowed to touch, violating
# the one invariant a no-CAW volume rests on: only one node ever writes to it.
#
# The gate now runs BEFORE registration: read the registry, and if a live
# FOREIGN node is already mounted, refuse WITHOUT claiming a row. This suite
# proves exactly that -- the refused mount leaves no new row behind -- and the
# negative control proves it does not over-refuse (a stale/dead peer is not a
# live one, so that mount proceeds).
#
# A loop device has no CAW, so the gate always runs here. The hard part is
# making a poked row look ALIVE: the gate watches hb_seq across a window, so a
# static poke reads as dead. A background beater advances the peer's hb_seq
# during the (compressed) window to impersonate a heartbeating node.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 nocaw)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nocaw)"
ct_mkfs_small "$DEV" -M 4 >/dev/null

# Count registry rows that are NOT free (state != 0). On a fresh volume with
# nothing mounted, this is 0.
nonfree_rows() {
    local n=0 r st
    for r in 0 1 2 3; do
        st="$("$POKE" "$DEV" "$r" 2>/dev/null | sed -n 's/^state=\([0-9]*\).*/\1/p')"
        [ "${st:-0}" != 0 ] && n=$((n + 1))
    done
    echo "$n"
}

# A foreign REGISTERED row so nonfree_rows starts at 1 (uuid all-0xAA, not
# this machine's uuid; last_seen=now).
"$POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
blockdev --flushbufs "$DEV"
[ "$(nonfree_rows)" = 1 ] && pass "only the poked foreign row is registered before the attempt" ||
    fail "setup wrong: $(nonfree_rows) non-free rows, expected 1"

log "a live foreign peer: mount must be refused, and leave NO new row"
# A heartbeating peer cannot be simulated reliably on the loop harness -- a
# userspace beater's writes race the kernel's uncached registry reads across
# the gate's multi-second watch, so the verdict is a coin flip. Force it with
# a test-only module param instead (restored at ct_exit), the same approach
# fence_skip_precheck takes for an equally un-simulable condition.
ct_param_set nocaw_force_live_peer 1
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    MOUNTED=1; umount "$MNT"
else
    MOUNTED=0
fi
blockdev --flushbufs "$DEV"
[ "$MOUNTED" = 0 ] && pass "the mount was refused (a live peer owns this no-CAW volume)" ||
    fail "the mount SUCCEEDED despite a live foreign peer on a no-CAW volume"
# THE assertion: the refused mount registered nothing. Still exactly one
# non-free row (the poked peer) -- not two. With the pre-registration gate
# reverted, the mounter would have claimed a free row before refusing, and
# this would read 2.
AFTER="$(nonfree_rows)"
[ "$AFTER" = 1 ] && pass "the refused mount claimed NO registry row (still 1 non-free row, the peer)" ||
    fail "the refused mount left $AFTER non-free rows -- it registered before refusing"

log "control: no live peer -- the mount proceeds (and the force knob really was what refused it)"
# Knob off, and the poked row departs (last_seen=0, the clean-departure
# sentinel the gate skips), so there is no live peer: the mount must proceed.
ct_param_set nocaw_force_live_peer 0
"$POKE" "$DEV" 1 1 aa 0 >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    require_cetrafs_mount "$MNT"
    pass "a no-CAW volume with no live peer mounts normally (the gate does not over-refuse)"
    : >"$MNT/proof"
    [ -e "$MNT/proof" ] && pass "and it is writable (this node registered and claimed a ZG)" ||
        fail "mounted but not writable"
    ct_umount "$MNT"
else
    fail "the gate refused a mount with no live peer -- it over-refuses, or the force knob stuck on"
fi

# Clear the poked foreign row so the volume is pristine for fsck.
"$POKE" "$DEV" 1 0 aa 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
