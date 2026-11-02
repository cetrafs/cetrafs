#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node with atomic CAW refuses to join a volume a live peer runs without it
#
# A node whose device has no atomic COMPARE AND WRITE runs the
# single-mounter fallback (read-modify-write under a node-local mutex) and
# refuses to mount while any peer is live. But that refusal happens only
# at ITS mount: a no-CAW node that mounted first -- alone, or because a
# transient failure of the Block Limits VPD probe made a CAW-capable LUN
# look like one without -- was never seen by a CAW node joining after it.
# The joiner then swapped with real CAW while the first node's swaps were
# exclusive only against itself, and both could win every lock.
#
# The no-CAW node now advertises CETRAFS_NODE_CAP_NO_CAW in its registry
# row, and a CAW node refuses to mount while a live peer advertises it.
# A loop device has no CAW, so mount_assume_caw makes this node take the
# CAW side's mount decisions; the peer is a registry row posed by
# node_poke.
#
# DISCRIMINATION (measured with the refusal removed): the CAW-side mount
# succeeds next to the live no-CAW peer.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

NODE_POKE="$(ct_helper node_poke)"
DEV="$(ct_dev 560 cawmix)"
MNT="$(ct_mnt cawmix)"
ct_mkfs_small "$DEV" >/dev/null

caps_of() { "$NODE_POKE" "$DEV" "$1" | grep -oP 'caps=\K0x[0-9a-f]+'; }

log "a node mounting without CAW says so in its row"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
C="$(caps_of 0)"
[ $((C & 0x2)) -ne 0 ] && pass "row 0 advertises NO_CAW (caps $C)" ||
    fail "row 0 advertises caps $C -- a CAW node joining later cannot see that this one has no CAW"
umount "$MNT"

# A live peer in row 1, running without CAW.
"$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null
"$NODE_POKE" "$DEV" 1 --caps 0x3 >/dev/null

log "a node with CAW mounting next to it"
ct_param_set mount_assume_caw 1
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_track mnt "$MNT"
    fail "the CAW node mounted next to a live peer running without CAW"
    umount "$MNT"
else
    pass "the CAW node refused to mount"
    dmesg_since "$MARK" | grep -q 'without atomic CAW' &&
        pass "and said why: a live node runs the volume without atomic CAW" ||
        fail "the mount failed, but not for the no-CAW peer (see dmesg)"
fi

log "control: the same peer WITH CAW does not stop it"
"$NODE_POKE" "$DEV" 1 --caps 0x1 >/dev/null
if ct_mount "$DEV" "$MNT"; then
    pass "the CAW node mounted next to a live CAW peer (the refusal is about the peer's mode)"
    C="$(caps_of 0)"
    [ $((C & 0x2)) -eq 0 ] && pass "and advertises no NO_CAW (caps $C)" ||
        fail "a CAW mount advertises NO_CAW (caps $C)"
    umount "$MNT"
else
    fail "control: the CAW node could not mount next to a CAW peer -- the refusal above proves nothing"
fi
ct_param_set mount_assume_caw 0

"$NODE_POKE" "$DEV" 1 0 cc 0 >/dev/null 2>&1 || true
ct_exit
