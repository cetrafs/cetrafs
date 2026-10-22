#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# this node's own registry row keeps advancing on its own
#
# The periodic half of liveness: our row's hb_seq must keep moving while
# mounted, not just once at registration. A node whose heartbeat silently
# stopped would have its ZGs and locks reclaimed out from under it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

# BEFORE the mount, not after: cetrafs_heartbeat_start() queues the first
# tick with whatever the interval is at mount time, so compressing later
# would still leave the first tick up to the production 15s away -- and
# the short sleeps below would race it.
compress_timing

# A volume with one file, 'victim', whose inode number the pokes below
# address. Every suite that touches the on-disk lock fields starts from
# exactly this state, freshly built -- nothing here inherits anything
# from another suite.
LOCK_IMG="$(ct_image 560 lock)"
LOCK_LOOPDEV="$(ct_loop "$LOCK_IMG")"
LOCK_MNT="$(ct_mnt lock-mnt)"
ct_mkfs_small "$LOCK_LOOPDEV" >/dev/null
ct_track mnt "$LOCK_MNT"
ct_mount "$LOCK_LOOPDEV" "$LOCK_MNT"
require_cetrafs_mount "$LOCK_MNT"
echo "victim content" >"$LOCK_MNT/victim"
VICTIM_INO="$(stat -c '%i' "$LOCK_MNT/victim")"

log "checking periodic heartbeat renewal"
# Mounted by the prologue above as the only (real) node, so our own row
# is index 0. This node's own row
# must keep advancing on its own while mounted, not just once at
# registration -- that's the entire point of "periodic".
#
# The production interval is kmod.h's CETRAFS_HEARTBEAT_INTERVAL_SECS
# (15s), which would mean sleeping ~25s to be sure of catching a tick on
# a busy host. hb_interval_secs exists precisely so a test does not pay
# that: compress it and wait several of the compressed ticks instead.
# What is under test is that the row advances on its own, not how long
# the interval is.
HB1="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
HB1_SEQ="$(echo "$HB1" | grep -oP 'hb_seq=\K[0-9]+')"
sleep $((TEST_HB_SECS * 4))
HB2="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
HB2_SEQ="$(echo "$HB2" | grep -oP 'hb_seq=\K[0-9]+')"
[ "$HB2_SEQ" -gt "$HB1_SEQ" ] && pass "heartbeat: our own row's hb_seq advanced on its own while mounted ($HB1_SEQ -> $HB2_SEQ)" ||
    fail "heartbeat: our own row's hb_seq did not advance ($HB1 -> $HB2)"
reset_stale_window


ct_exit
