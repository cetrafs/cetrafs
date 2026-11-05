#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tool waits as long as the kernel before calling a node gone
#
# The stale window is 120 s because a node whose paths have all failed
# has its I/O queued by multipath for up to 90 s -- heartbeats included
# -- and then it all lands (cetrafs.h, CETRAFS_NODE_STALE_SECS). A peer
# waits that long. mkfs, fsck -r and growfs watched a row for two beats
# plus 5 s, 35 s at a 15 s interval, then formatted or repaired a
# volume such a node was about to write to.
#
# And a node's stale window is an operator control (stale_secs, up to
# CETRAFS_STALE_MAX_SECS = 240 s) that is not on the device, so a tool
# waits the longest any node may use (audit F9).
#
# Staged: a registered row (15 s interval) whose beats stop for 150 s
# -- past the 120 s default, inside the 240 s maximum -- and then
# resume, as a node's would when its paths come back. mkfs -f must see
# it and refuse.
#
# DISCRIMINATION: with the two-beat window mkfs gives up at 35 s, and
# with the default window at 120 s; both format the volume.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
unset CETRAFS_PEER_PROBE_SECS

IMG="$(ct_image 560 probewin)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" -N 2048 >/dev/null
blockdev --flushbufs "$DEV"
SB="$IMG.sb"; ct_track file "$SB"
dd if="$IMG" of="$SB" bs=4096 count=1 status=none
OLD="$(sha256sum <"$SB")"

"$NPOKE" "$IMG" 1 1 bb "$(date +%s)" 15 >/dev/null
grep -q 'state=1 .*hb_interval=15' <<<"$("$NPOKE" "$IMG" 1)" ||
    { fail "setup: the registered row was not planted: $("$NPOKE" "$IMG" 1)"; ct_exit; }
# Its paths are down for 150 s, then its queued beats land. Geometry off
# the saved superblock: mkfs has zeroed block 0 by then.
( sleep 150; for _ in $(seq 1 20); do NODE_POKE_SB="$SB" "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1 || true; sleep 1; done ) &
BEATER=$!
blockdev --flushbufs "$DEV"
pass "setup: a node registered at a 15 s interval, silent for 150 s"

T0="$(date +%s)"
OUT="$("$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)" && RC=0 || RC=$?
T1="$(date +%s)"
kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true
log "mkfs exited $RC after $((T1 - T0)) s"
[ "$RC" != 0 ] && grep -q 'mounted by another node' <<<"$OUT" &&
    pass "mkfs saw the node come back and refused" ||
    fail "mkfs formatted a volume whose node was only stalled (watched $((T1 - T0)) s): $(tail -1 <<<"$OUT")"
blockdev --flushbufs "$DEV"
[ "$(dd if="$IMG" bs=4096 count=1 status=none | sha256sum)" = "$OLD" ] &&
    pass "and the volume's superblock is the old one" || fail "block 0 is not the old superblock"
ct_exit
