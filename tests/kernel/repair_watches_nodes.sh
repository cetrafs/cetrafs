#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r and growfs stop when a node starts beating under their claim
#
# A repair or grow holds a registry row in REPAIR, and the mount gate
# refuses a mount while that claim looks live. Only while it LOOKS live:
# a repairer whose renewals are queued behind dead paths goes still, a
# mounting node judges the claim dead and mounts, and the tools probed
# for a live node only once, at the start -- so the repair carried on
# with blind full-block writes under a live mount (audit R4, tool half).
# The claim's renewal timer now also looks at every other row and stops
# the tool when a REGISTERED one has beaten since the claim was taken; a
# refused mount never writes its row, so a moving hb_seq is a node that
# got in.
#
# Staged: the tool holds its claim (CETRAFS_TEST_REPAIR_HOLD_SECS), and
# this node's departed row is beaten on the device as a mount that got
# past the gate would.
#
# CONTROL: the same run with no beat completes -- the watch does not fire
# on the registry as the claim found it.
# DISCRIMINATION: the previous tools finish both runs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
GROWFS="$ROOT/userspace/growfs.cetra"
MAP="$(ct_helper bg_map)"
# Row NID is beaten by this suite, so every tool's live-peer probe would
# watch it for the full stale window: shorten it (test knob, devutil.h).
export CETRAFS_PEER_PROBE_SECS=3

DEV="$(ct_big_dev 1400 repwatch)"
MNT="$(ct_mnt repwatch)"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo data >"$MNT/f"
ct_umount "$MNT"

# run_tool <out> <beat:0|1> <cmd...>: run a claim-holding tool for 12 s
# of hold; with beat=1, beat row NID twice while it holds. Echo its rc.
run_tool() {
    local out="$1" beat="$2" pid i rc=0
    shift 2
    CETRAFS_TEST_REPAIR_HOLD_SECS=12 "$@" >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 50); do
        grep -q "claimed registry row" "$out" && break
        sleep 0.2
    done
    grep -q "claimed registry row" "$out" || { kill -9 "$pid"; fail "setup: the tool never claimed a row: $(head -3 "$out")"; ct_exit; }
    if [ "$beat" = 1 ]; then
        "$NPOKE" "$DEV" "$NID" --beat >/dev/null
        sleep 6
        "$NPOKE" "$DEV" "$NID" --beat >/dev/null
    fi
    wait "$pid" || rc=$?
    echo "$rc"
}

O="$(ct_tmp repwatch-out)"
RC="$(run_tool "$O" 0 "$FSCK" -r "$DEV")"
[ "$RC" -le 1 ] && ! grep -q "while it is being repaired" "$O" &&
    pass "control: fsck -r with no node beating completes (rc $RC)" ||
    fail "control: fsck -r stopped with nobody beating (rc $RC): $(grep -m2 ERR "$O")"

RC="$(run_tool "$O" 1 "$FSCK" -r "$DEV")"
grep -q "a node is mounted on this volume while it is being repaired" "$O" && [ "$RC" -gt 1 ] &&
    pass "fsck -r stopped when a node beat under its claim (rc $RC)" ||
    fail "fsck -r carried on with a node beating under its claim (rc $RC): $(tail -2 "$O")"

COUNTS0="$("$MAP" "$DEV" | sed -n 's/^counts //p')"
RC="$(run_tool "$O" 1 "$GROWFS" "$DEV")"
grep -q "a node is mounted on this volume while it is being grown" "$O" && [ "$RC" != 0 ] &&
    pass "growfs stopped when a node beat under its claim (rc $RC)" ||
    fail "growfs carried on with a node beating under its claim (rc $RC): $(tail -2 "$O")"
COUNTS1="$("$MAP" "$DEV" | sed -n 's/^counts //p')"
[ "$COUNTS1" = "$COUNTS0" ] && pass "and published nothing (zone/block groups still $COUNTS1)" ||
    fail "growfs published a grow after the node appeared ($COUNTS0 -> $COUNTS1)"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean: the stopped tools left a consistent volume"
ct_exit
