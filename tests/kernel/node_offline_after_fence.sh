#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node fenced since its last renewal does not announce a clean departure
#
# A clean departure is recorded in the node's own Node Registry row. A
# peer that revokes the node's lease bumps the row's fence_epoch. The
# node's heartbeat notices that once a tick, so for up to a tick the
# in-core state still says "not fenced": unmount then recorded a CLEAN
# departure on a node whose lease was already gone, and the next mount
# skipped its claim sweep (audit C8). The departure mutator now compares
# the row's fence_epoch with the epoch this node last renewed under, and
# writes nothing when they differ.
#
# Staged: a heartbeat interval far longer than the test, so no tick runs.
#  1. control: an unmount with no peer revocation records departure=1 (CLEAN).
#  2. a peer bumps the fence after this node's last renewal, then the node
#     unmounts: the row keeps the peer's epoch and records no departure.
#
# DISCRIMINATION: without the epoch check (the pre-fix mutator) case 2 records
# departure=1 over the peer's revocation.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 offfenced)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt offfenced)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 30

row0() { "$NPOKE" "$IMG" 0 2>&1; }
epoch_of() { row0 | sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' | head -1; }
departure_of() { row0 | sed -n 's/.* departure=\([0-9]*\).*/\1/p' | head -1; }

# ------------------------------------------------------------------- 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
D1="$(departure_of)"
[ "$D1" = 1 ] && pass "1: control: an unmount with no peer revocation records a clean departure" ||
    fail "1: control: the clean departure was not recorded (departure='$D1')"

# ------------------------------------------------------------------- 2
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
D2="$(departure_of)"
[ "$D2" = 0 ] || { fail "setup: the remount did not clear the departure (departure='$D2')"; ct_exit; }
BEFORE="$(epoch_of)"
"$NPOKE" "$IMG" 0 --bump-fence 1 >/dev/null 2>&1 ||
    { fail "setup: could not bump the fence epoch -- the setup did not arrange the situation"; ct_exit; }
BUMPED="$(epoch_of)"
[ -n "$BUMPED" ] && [ "$BUMPED" -gt "$BEFORE" ] ||
    { fail "setup: the bump did not take ($BEFORE -> $BUMPED)"; ct_exit; }
ct_umount "$MNT" 2>/dev/null || true
AFTER="$(epoch_of)"
D3="$(departure_of)"
[ "$AFTER" = "$BUMPED" ] && pass "2: the peer's revocation stands after the unmount (epoch $AFTER)" ||
    fail "2: the unmount changed the fence epoch ($BUMPED -> $AFTER)"
[ "$D3" = 0 ] && pass "2: and the fenced node recorded no clean departure" ||
    fail "2: a fenced node announced a clean departure (departure=$D3) over a peer's revocation"
ct_exit
