#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow must refuse unless EVERY registered node advertises support
#
# The layout moves under every mounted node's cached, lockless Block
# Group table offsets when a volume grows, and only a node that
# understands layout_gen (CETRAFS_NODE_CAP_LIVE_GROW) re-reads them.
# cetrafs_node_entry_t.caps is where each node advertises that, carved
# from the row's zero-filled reserved area -- so a node that predates it
# (a 0.8.x build, or any row never written by this module) reads 0 and is
# correctly excluded. cetrafs_cluster_all_advertise() is the gate a live
# grow stands on; the `cluster` procfs surfaces its verdict as
# "live_grow_ready: yes|no" and each row's advertised caps.
#
# This proves: (1) a node running this build advertises the bit and the
# gate passes; (2) a single old-style row (caps=0) flips the gate to no.
# Without (2) the gate could be hard-wired to "yes" and this test would
# not notice. And (3): the same row recorded DEAD (a reclaim fence or a
# declaration) no longer blocks it -- the gate said it skipped departed
# rows and did not (audit 2026-11-15 M-28). DISCRIMINATION for (3):
# caps_gate_departed=1, the gate counts it and says no.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

POKE="$(ct_helper node_poke)"
IMG="$(ct_image 560 nodecaps)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nodecaps)"
ct_mkfs_small "$DEV" -M 4 >/dev/null

CLUSTER="$(ct_procdir "$DEV")/cluster"

# ---- (1) a node on this build advertises the capability ----
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

grep -q "(this node)" "$CLUSTER" &&
    pass "this node has a registered row in the cluster view" ||
    fail "this node is not in the cluster view -- registration did not take"

MYLINE="$(grep "(this node)" "$CLUSTER")"
# Test the bit, not the whole word: a loop device has no CAW, so the
# row also carries CETRAFS_NODE_CAP_NO_CAW (0x2).
MYCAPS="$(printf '%s\n' "$MYLINE" | grep -o "caps=0x[0-9a-f]*" | cut -d= -f2)"
[ -n "$MYCAPS" ] && [ $((MYCAPS & 0x1)) -ne 0 ] &&
    pass "this node advertises CETRAFS_NODE_CAP_LIVE_GROW (caps=$MYCAPS)" ||
    fail "this node's row does not advertise the live-grow cap: $MYLINE"

grep -q "^live_grow_ready: yes" "$CLUSTER" &&
    pass "live_grow_ready is yes with only this build's node registered" ||
    fail "live_grow_ready is not yes with a single capable node: $(grep live_grow_ready "$CLUSTER")"

ct_umount "$MNT"

# ---- (2) one old-style row (caps=0) must flip the gate ----
# node_poke writes a REGISTERED row with the reserved area (caps included)
# left zero -- exactly the row an old module would leave. Our own row is
# 0; poke a DIFFERENT row as the peer -- after the mount, which would
# otherwise watch the silent row out and record it DEAD (a departed row
# is skipped, part 3).
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$POKE" "$DEV" 1 1 ab "$(date +%s)" >/dev/null

# Read the verdict immediately, before any stale-reclaim tick could
# record the poked row dead (default window; nothing compresses it here).
VERDICT="$(grep "^live_grow_ready:" "$CLUSTER")"
PEERCAPS="$(grep -v "(this node)" "$CLUSTER" | grep "state=REGISTERED" | grep -o "caps=0x[0-9a-f]*" | sort -u | tr '\n' ' ')"

printf '%s\n' "$VERDICT" | grep -q "no" &&
    pass "live_grow_ready flipped to no with an old-style (caps=0) row present [$PEERCAPS]" ||
    fail "live_grow_ready did not flip despite a caps=0 row: $VERDICT [$PEERCAPS]"

ct_umount "$MNT"

# ---- (3) the same row, recorded DEAD, does not block it ----
ct_param_set caps_gate_departed 0
"$POKE" "$DEV" 1 --depart 2 >/dev/null
blockdev --flushbufs "$DEV" 2>/dev/null || true
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
D3="$(grep "^live_grow_ready:" "$CLUSTER")"
echo 1 >/sys/module/cetrafs/parameters/caps_gate_departed
C3="$(grep "^live_grow_ready:" "$CLUSTER")"
echo 0 >/sys/module/cetrafs/parameters/caps_gate_departed
[ "$("$POKE" "$DEV" 1 | tr ' ' '\n' | sed -n 's/^departure=//p')" = 2 ] ||
    { fail "setup: row 1 is not recorded DEAD"; ct_exit; }
printf '%s\n' "$D3" | grep -q "yes" &&
    pass "3: a caps=0 row recorded DEAD does not block a grow ($D3)" || fail "3: $D3"
printf '%s\n' "$C3" | grep -q "no" &&
    pass "3 control: counting departed rows, the same row blocks it ($C3)" ||
    fail "3 control: $C3 -- the suite does not reach the departed row"
ct_umount "$MNT"
ct_exit
