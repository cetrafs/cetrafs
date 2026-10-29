#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live foreign ZG claim refuses the mount on a device with no CAW
#
# A device with no atomic COMPARE AND WRITE has no cross-node mutual
# exclusion at all, so it can only ever have ONE mounter -- fill_super
# must refuse a volume some other live node has already claimed a ZG on.
# This gate is load-bearing well beyond the mount: it is what lets the
# no-CAW CAS fallback be a plain read-modify-write, and what lets a free
# aimed at a foreign ZG be applied directly instead of queued.
#
# The third case is the one that matters most: a claim whose owner has
# STOPPED heartbeating must NOT block the mount, or a surviving node
# could never remount past a crashed peer's abandoned ZG.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
ZG_POKE="$(ct_helper zg_poke)"

log "checking the no-exclusion mount-refusal gate: a foreign ZG claim refuses the mount"
# Independent throwaway image/loop device -- doesn't touch $LOOPDEV/$MNT,
# which the rest of this script stays mounted on for the file-op tests
# below. Our loop-device harness has no atomic CAW, which is exactly the
# condition the gate tests: with no cross-node mutual exclusion a volume
# can only ever have one mounter, so an existing foreign claim must
# refuse it. A CAW-capable device skips the gate entirely -- coexistence
# there is the normal, supported case.
GATE_IMG="$(mktemp /tmp/cetrafs-gate-XXXXXX.img)"
truncate -s 560M "$GATE_IMG"
GATE_LOOPDEV="$(losetup --find --show "$GATE_IMG")"
GATE_MNT="$(mktemp -d /tmp/cetrafs-gate-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$GATE_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

# First mount: legitimately claims node row 0 and ZG0 for this (the only
# real) node -- establishes the baseline before we fake a foreign claim.
mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT"
require_cetrafs_mount "$GATE_MNT"
umount "$GATE_MNT"

# Simulate "ZG0 is already claimed by some other, still-alive node":
# poke a fake REGISTERED row at index 1 with a fresh last_seen
# (the gate is stale-aware -- see zonegroup.c's cetrafs_zg_foreign_claim_exists()
# -- so the foreign claim must belong to a node that's actually alive, not just
# any out-of-thin-air id, or the gate would correctly let it through for
# reclaim instead of refusing). fsck doesn't cross-check ZG ownership against the Node
# Registry, so a structurally-valid, correctly checksummed pair of
# pokes is all this needs.
#
# "Alive" now means its hb_seq is MOVING, not that its timestamp looks
# recent -- a timestamp proves nothing between machines whose clocks
# disagree. So this has to actually beat the row while the gate watches,
# which is what the background loop below does. The gate's probe runs
# for stale_secs, so compress that first or the test waits a minute.
set_stale_window "$TEST_STALE_SECS"
"$NODE_POKE" "$GATE_LOOPDEV" 1 1 bb "$(date +%s)" >/dev/null
"$ZG_POKE" "$GATE_LOOPDEV" 0 1 >/dev/null

gate_beat() {
    for _ in $(seq 1 $((TEST_STALE_SECS + 6))); do
        "$NODE_POKE" "$GATE_LOOPDEV" 1 --beat >/dev/null 2>&1 || true
        sleep 1
    done
}
gate_beat &
GATE_BEATER=$!
DMESG_MARK_GATE="$(dmesg_mark)"
GATE_MOUNT_RC=0
mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT" 2>/dev/null || GATE_MOUNT_RC=$?
kill "$GATE_BEATER" 2>/dev/null || true
wait "$GATE_BEATER" 2>/dev/null || true

# The refusal only counts if it came from the GATE. The beater holds the
# device O_RDWR, and a mount wants it exclusively, so a mount here can
# also fail with plain EBUSY -- an unrelated failure that looks
# identical from the exit status alone and would let this assertion pass
# while the gate did nothing.
GATE_LOG="$(dmesg_since "$DMESG_MARK_GATE")"
if [ "$GATE_MOUNT_RC" = "0" ]; then
    fail "gate: mount unexpectedly succeeded on a no-CAW device with a foreign ZG claim"
    umount "$GATE_MNT"
elif echo "$GATE_LOG" | grep -q 'another node is already mounted on it'; then
    pass "gate: mount refused BY THE GATE when a live peer is mounted on a no-CAW device"
else
    fail "gate: mount failed, but not because of the gate (no 'already mounted' line) -- likely EBUSY"
fi

# The control for the two assertions above: the ONLY thing that changes
# is whether anything is advancing that row's heartbeat. A gate that
# always refused would pass them and fail here.
if mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT" 2>/dev/null; then
    pass "gate: the same foreign claim no longer blocks the mount once its node stops heartbeating"
    umount "$GATE_MNT"
else
    fail "gate: a foreign claim whose node is dead blocked the mount forever"
fi

# ------------------------------------------------------------------
# A mounted node need own no Zone Group at all.
#
# The gate used to ask "does any other node own a ZG?", which a
# read-only mount answers "no" by design -- it claims none, while still
# registering, heartbeating and publishing read-presence bits, every one
# of which is a write needing the atomicity this device does not have.
# So a read-only peer was completely invisible and a second node walked
# straight in. The question is asked of the Node Registry now: is
# anybody else MOUNTED.
log "a live peer that owns no Zone Group still refuses the mount"
"$ZG_POKE" "$GATE_LOOPDEV" 0 65535 >/dev/null   # give the ZG back: nobody owns anything
"$NODE_POKE" "$GATE_LOOPDEV" 1 1 bb "$(date +%s)" >/dev/null
gate_beat &
GATE_BEATER=$!
DMESG_MARK_RO="$(dmesg_mark)"
RO_RC=0
mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT" 2>/dev/null || RO_RC=$?
kill "$GATE_BEATER" 2>/dev/null || true
wait "$GATE_BEATER" 2>/dev/null || true
if [ "$RO_RC" = "0" ]; then
    fail "gate: a live peer owning no ZG let a second node mount a volume with no cross-node atomicity"
    umount "$GATE_MNT"
elif dmesg_since "$DMESG_MARK_RO" | grep -q 'another node is already mounted on it'; then
    pass "gate: a live peer that owns no Zone Group still refuses the mount"
else
    fail "gate: the mount failed but not from the gate -- likely EBUSY"
fi

# Same control: with nothing beating that row, the mount goes through.
wait_out_stale_window
if mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT" 2>/dev/null; then
    pass "gate: control -- with nobody beating, a volume owned by nobody mounts fine"
    umount "$GATE_MNT"
else
    fail "gate: the mount was refused with no live peer and no claim at all"
fi


# ------------------------------------------------------------------
# The window must be measured in the PEER's beats, not our patience.
#
# P17 fixed exactly this in cetrafs_node_is_stale() and did not fix it
# here, because the enumeration was by function rather than by property.
# The probe slept the OBSERVER's stale_secs, which says how long we are
# willing to wait and nothing about how often the peer beats -- so a
# peer beating more slowly than our window reads as dead and the gate
# admits a SECOND mounter to a volume with no cross-node atomicity.
#
# One beat, at a fixed moment, is what makes this deterministic in both
# directions: the old window (2s) ends before it, the new one (four of
# the peer's advertised 3s beats = 12s) contains it.
log "the probe waits for the PEER's beat rate, not the observer's"
set_stale_window 2
"$NODE_POKE" "$GATE_LOOPDEV" 1 1 bb "$(date +%s)" 3 >/dev/null
(
    sleep 6
    "$NODE_POKE" "$GATE_LOOPDEV" 1 --beat >/dev/null 2>&1 || true
) &
SLOW_BEATER=$!
DMESG_MARK_SLOW="$(dmesg_mark)"
SLOW_RC=0
mount -t cetrafs "$GATE_LOOPDEV" "$GATE_MNT" 2>/dev/null || SLOW_RC=$?
wait "$SLOW_BEATER" 2>/dev/null || true
if [ "$SLOW_RC" = "0" ]; then
    fail "gate: a peer beating every 3s was declared dead by a 2s window -- two nodes now share a no-CAW volume"
    umount "$GATE_MNT"
elif dmesg_since "$DMESG_MARK_SLOW" | grep -q 'another node is already mounted on it'; then
    pass "gate: a peer slower than our own window is still seen as alive"
else
    fail "gate: the mount failed but not from the gate -- likely EBUSY"
fi

reset_stale_window

rmdir "$GATE_MNT"
losetup -d "$GATE_LOOPDEV"
rm -f "$GATE_IMG"


ct_exit
