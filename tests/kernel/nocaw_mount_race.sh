#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# No-CAW single-mounter: the POST-registration re-check refuses a lost race
#
# The pre-registration gate (nocaw_mount_gate.sh) reads the registry BEFORE
# this node registers, so two nodes mounting the same no-CAW volume at the
# same instant can each pass it before the other's row exists -- and with no
# atomic CAW nothing arbitrates the two registrations (the row claim degrades
# to a node-LOCAL mutex). Both nodes would come up writing to a volume with
# no cross-node mutual exclusion at all: the exact catastrophe the gate
# exists to prevent, through the window the gate cannot see.
#
# The fix is a re-check AFTER registration: our row is committed, so a racer
# is now visible; if ANY live foreign row exists, unwind and refuse. This
# suite proves the refusal, the unwind (no live row left behind -- a later
# mount must not inherit a phantom peer to wait out), and that the volume
# mounts normally afterwards.
#
# Two genuinely-racing mounters cannot be simulated single-node, so the
# lost-race verdict is forced with a test-only module param (restored at
# ct_exit), the same approach as nocaw_force_live_peer in the gate suite.
# The knob is read ONLY by cetrafs_node_single_mounter_conflict(), which
# ONLY the new fs.c re-check calls -- so with the re-check reverted, the
# mount succeeds despite the knob and the first assertion fails: this test
# discriminates.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 nocawrace)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nocawrace)"
ct_mkfs_small "$DEV" -M 4 >/dev/null

# Any registry row a later mount's gate would WAIT on: REGISTERED with
# last_seen != 0. A clean unwind leaves none (the released row keeps
# state=REGISTERED but backdates last_seen to 0, the departure sentinel).
live_rows() {
    local n=0 r line st ls
    for r in 0 1 2 3; do
        line="$("$POKE" "$DEV" "$r" 2>/dev/null)" || continue
        st="$(sed -n 's/^state=\([0-9]*\).*/\1/p' <<<"$line")"
        ls="$(sed -n 's/.*last_seen=\([0-9]*\).*/\1/p' <<<"$line")"
        [ "${st:-0}" != 0 ] && [ "${ls:-0}" != 0 ] && n=$((n + 1))
    done
    echo "$n"
}

log "a racer registered while we mounted: the mount must be refused AFTER registering"
ct_param_set nocaw_force_postreg_peer 1
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    MOUNTED=1; umount "$MNT"
else
    MOUNTED=0
fi
blockdev --flushbufs "$DEV"
[ "$MOUNTED" = 0 ] && pass "the mount was refused (lost the simultaneous-mount race)" ||
    fail "the mount SUCCEEDED despite a racer's row on a no-CAW volume -- the re-check is gone"
mountpoint -q "$MNT" && fail "something is still mounted on $MNT after the refusal" ||
    pass "nothing left mounted after the refusal"

# THE unwind assertion: the refused mount released the row it claimed. A
# row left REGISTERED with a fresh last_seen would make every later mount's
# gate watch a full staleness window for a node that was never really there.
LIVE="$(live_rows)"
[ "$LIVE" = 0 ] && pass "the refused mount left no live registry row (clean unwind)" ||
    fail "the refused mount left $LIVE live row(s) -- the unwind did not release its registration"

log "control: no racer -- the same volume mounts normally (the knob was what refused it)"
ct_param_set nocaw_force_postreg_peer 0
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    require_cetrafs_mount "$MNT"
    pass "the volume mounts once the race verdict is gone (no over-refusal)"
    : >"$MNT/proof"
    [ -e "$MNT/proof" ] && pass "and it is writable (registered and claimed a ZG, same row re-attached)" ||
        fail "mounted but not writable"
    ct_umount "$MNT"
else
    fail "mount refused with no racer -- the re-check over-refuses, or the force knob stuck on"
fi

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
