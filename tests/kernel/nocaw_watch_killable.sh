#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a no-CAW mount waiting out a peer's watch window can be killed
#
# On a device with no atomic CAW, a mount that finds another node's row
# watches it for a stale window to see whether it still beats. It slept
# the window with ssleep(), uninterruptibly -- every other registry watch
# is killable -- so an operator could not give up on a mount waiting out
# a dead peer (audit 2026-11-06 L6).
#
# Staged: a dead-looking peer row and a 30 s stale window. The mount is
# killed 2 s into its watch: it must be gone within 2 s more, and must
# not have mounted.
#
# DISCRIMINATION: with ssleep() the kill waits out the window.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 nocawkill)"
MNT="$(ct_mnt nocawkill)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
ct_param_set stale_secs 30

MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null &
MPID=$!
for _ in $(seq 1 40); do
    dmesg_since "$MARK" | grep -q "to see whether 1 other node" && break
    sleep 0.25
done
dmesg_since "$MARK" | grep -q "to see whether 1 other node" ||
    { fail "setup: the mount never started watching the peer row"; wait "$MPID" || true; umount "$MNT" 2>/dev/null || true; ct_exit; }
sleep 2
T0="$(date +%s%N)"
kill -9 "$MPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
MS=$((($(date +%s%N) - T0) / 1000000))
if mountpoint -q "$MNT"; then
    fail "the killed mount mounted anyway"
    umount "$MNT"
else
    pass "the killed mount did not mount"
fi
[ "$MS" -lt 2000 ] && pass "the mount died on SIGKILL in ${MS} ms, inside its peer watch" ||
    fail "the mount took ${MS} ms to die on SIGKILL -- it slept out the watch window"
ct_exit
