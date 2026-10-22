#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The file-lock mode is cluster-wide: the FIRST mounter leads, every node
# after it INHERITS that mode instead of its own default, and a node that
# explicitly asks for the opposite is REFUSED at mount.
#
# A mixed on/off cluster has no coherent cross-node locking and silently
# corrupts (a default-mount node auto-locks images a nofilelock peer writes
# without locking, and trusts its own stale metadata cache), so this makes
# a mixed cluster unformable rather than merely discouraged.
#
# The "inherit a live peer's mode" path needs a live peer, which the no-CAW
# mount gate refuses outright on a loop device -- so it is only reachable on
# real CAW hardware (ctest's job). Here the observed cluster mode is forced
# with a test knob so the inherit/refuse DECISION in fill_super is exercised
# single-node; ctest covers the real cross-node scan.
#
# Discriminator: without the feature, a default mount is always file_lock on
# and a nofilelock mount always succeeds -- parts 3 and 4 fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 clm)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt clm)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" >/dev/null

lockmode() { sed -n 's/^file_lock: //p' "/proc/fs/cetrafs/$PROC_DEV/info"; }
# CETRAFS_FLOCK_MODE_*: 1 = on, 2 = off; -1 = real scan (no force).
FORCE=force_cluster_flock_mode

# ---------------------------------------------------------------- part 1
# No live peer -> this node LEADS with its own option (default on).
log "lead: no peer, default mount -> file_lock on"
ct_mount "$DEV" "$MNT"; require_cetrafs_mount "$MNT"
[ "$(lockmode)" = on ] && pass "lead with default -> file_lock on" || fail "lead default: got '$(lockmode)'"
ct_umount "$MNT"

# ---------------------------------------------------------------- part 2
log "lead: no peer, -o nofilelock -> file_lock off"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"; require_cetrafs_mount "$MNT"
[ "$(lockmode)" = off ] && pass "lead with nofilelock -> file_lock off" || fail "lead nofilelock: got '$(lockmode)'"
ct_umount "$MNT"

# ---------------------------------------------------------------- part 3
# A live peer runs file_lock OFF; a node joining with its DEFAULT (on)
# inherits OFF rather than forming a mixed cluster.
log "inherit: cluster is OFF, default mount adopts OFF (not its own default on)"
ct_param_set "$FORCE" 2   # cluster lead = OFF
ct_mount "$DEV" "$MNT"; require_cetrafs_mount "$MNT"
[ "$(lockmode)" = off ] &&
    pass "default mount inherited file_lock off from the cluster lead" ||
    fail "did NOT inherit: default mount shows '$(lockmode)' against an OFF cluster"
ct_umount "$MNT"

# ---------------------------------------------------------------- part 4
# The cluster is ON; a node EXPLICITLY asking for nofilelock is refused
# (silently giving it the opposite of an explicit safety flag is worse).
log "refuse: cluster is ON, -o nofilelock is rejected at mount"
ct_param_set "$FORCE" 1   # cluster lead = ON
if mount -t cetrafs -o nofilelock "$DEV" "$MNT" 2>/dev/null; then
    fail "nofilelock mount against a lock-ON cluster SUCCEEDED -- mixed cluster allowed"
    ct_umount "$MNT"
else
    pass "nofilelock mount against a lock-ON cluster is refused"
fi
# Nothing should be mounted after a refused mount.
mountpoint -q "$MNT" && { fail "a refused mount left $MNT mounted"; ct_umount "$MNT"; } || pass "the refused mount left nothing behind"

# ---------------------------------------------------------------- part 5
# Same ON cluster, a default (on) node joins cleanly -- no spurious refuse.
log "inherit: cluster is ON, default mount joins as on"
ct_mount "$DEV" "$MNT"; require_cetrafs_mount "$MNT"
[ "$(lockmode)" = on ] && pass "default mount joins a lock-ON cluster as on" || fail "got '$(lockmode)'"
ct_umount "$MNT"

ct_param_set "$FORCE" -1   # restore real scan before the race test below

# ---------------------------------------------------------------- part 6
# Simultaneous-mount race: the pre-registration scan saw no peer (we lead),
# but by the time we registered a peer with a DIFFERENT mode had appeared.
# The post-registration re-check must catch it and REFUSE, rather than come
# up as a second lead with a divergent mode (a mixed, corrupting cluster).
# A real racing peer can't be conjured on a loop device, so force the
# post-registration conflict verdict.
log "race: a divergent peer appearing between scan and registration is refused"
ct_param_set force_mode_conflict 1
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    fail "a lost simultaneous-mount race was NOT refused -- mixed cluster allowed"
    ct_umount "$MNT"
else
    pass "a lost simultaneous-mount race is refused at mount"
fi
mountpoint -q "$MNT" && { fail "the refused race mount left $MNT mounted"; ct_umount "$MNT"; } || pass "the refused race mount left nothing behind"
ct_param_set force_mode_conflict 0

# The refused mount claimed a registry row then unwound it: it must NOT be
# left as a live REGISTERED row (which would make a peer wait out a staleness
# window). A fresh mount proves the volume is still cleanly mountable.
ct_mount "$DEV" "$MNT"; require_cetrafs_mount "$MNT"
pass "the volume still mounts cleanly after the refused race mount"
ct_umount "$MNT"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
