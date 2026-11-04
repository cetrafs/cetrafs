#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair that starts while a mount is in flight stops that mount
#
# fill_super() looks for an offline repairer (fsck -r, growfs) before it
# registers -- it must, a refused node may not write -- and only then.
# A repairer claiming the volume in between found no registered node
# (ours did not exist yet) and went ahead, and the mount came up
# allocating out of the structures the repair was rewriting.
#
# Staged: the mount is held between its gate and its registration
# (mount_register_stall_ms) while a renewing repair claim is planted.
# The mount must refuse.
#
# DISCRIMINATION: without the post-registration re-check the mount
# succeeds under the live claim.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/mount_register_stall_ms ] || { skip "mount_register_stall_ms missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 repairmid)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt repairmid)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ROW=3

ct_param_set mount_register_stall_ms 3000
MARK="$(dmesg_mark)"
RC=0
( mount -t cetrafs "$DEV" "$MNT" 2>/dev/null ) &
MPID=$!
sleep 1
# The repairer claims row 3 and keeps renewing it, as fsck -r does.
"$NPOKE" "$IMG" "$ROW" 2 aa "$(date +%s)" >/dev/null
( for _ in $(seq 1 30); do "$NPOKE" "$IMG" "$ROW" --beat >/dev/null 2>&1 || true; sleep 1; done ) &
RENEW=$!
ct_track cmd "kill $RENEW"
wait "$MPID" || RC=$?
kill "$RENEW" 2>/dev/null || true
wait "$RENEW" 2>/dev/null || true
ct_param_set mount_register_stall_ms 0
dmesg_since "$MARK" | grep -q "being repaired right now" &&
    { fail "setup: the gate itself saw the claim -- it was planted too early"; ct_exit; }
if [ "$RC" = 0 ]; then
    fail "the mount came up under a repair that started while it was in flight"
    umount "$MNT" 2>/dev/null || true
else
    pass "the mount refused (exit $RC)"
    dmesg_since "$MARK" | grep -q "started while this mount was in flight" &&
        pass "and said a repair started during the mount" || fail "refused, but not by the repair re-check"
fi
"$NPOKE" "$IMG" "$ROW" 0 00 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT" && pass "with the repair gone the volume mounts" || fail "the volume did not mount afterwards"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
ct_exit
