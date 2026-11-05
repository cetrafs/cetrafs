#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim gives its row back, however the repairer ends; a full registry can be cleared
#
# fsck -r and growfs hold a registry row in REPAIR for the duration. On
# a full registry they BORROW a departed node's row, and kept the row
# they displaced only in process memory:
#   - SIGTERM/SIGINT killed the tool with the claim on the device;
#   - SIGKILL or a crash, likewise, and nothing ever reaped it -- the
#     mount gate stopped treating it as a claim once it stood still, but
#     the row stayed REPAIR for good and the borrowed node's
#     registration was gone: on a full registry that node could not
#     mount again.
# And no path ever retired a departed row, so the N+1th distinct node
# identity got "registry full" until mkfs.
#
# Now: the tools release on the stop signals; the displaced row is kept
# in the claim's own block; a dead claim is reaped (kernel mount gate,
# and the tools' own watch) back to the row it borrowed; and fsck -r
# retires departed rows nothing references when the registry is full.
#
# Setup: a two-row registry, both rows departed nodes (this one and a
# poked "bb"), no FREE row -- so every claim below borrows.
#
# DISCRIMINATION: against the old tools and kernel, A and B leave the
# row in REPAIR, C finds no reap, D retires nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
ct_param_set stale_secs 20

IMG="$(ct_image 560 retire)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt retire)"
ct_mkfs_small "$DEV" -M 2 >/dev/null
ct_track mnt "$MNT"

# This node takes row 0 and leaves cleanly; row 1 is another departed node.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1 || fail "setup: could not register row 1"
state() { "$NPOKE" "$IMG" "$1" | sed -n 's/^state=\([0-9]*\) .*/\1/p'; }
[ "$(state 0)" = 1 ] && [ "$(state 1)" = 1 ] ||
    fail "setup: the registry is not two registered rows (row 0 state $(state 0), row 1 state $(state 1))"

# start_repair: fsck -r holding its claim; echoes "<pid> <row>".
start_repair() {
    local out pid row i
    out="$(ct_tmp retire-fsck)"
    CETRAFS_TEST_REPAIR_HOLD_SECS=120 "$FSCK" -r "$DEV" >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 100); do
        row="$(sed -n 's/^  claimed registry row \([0-9]*\) .*/\1/p' "$out")"
        [ -n "$row" ] && break
        sleep 0.2
    done
    [ -n "$row" ] || { kill -9 "$pid" 2>/dev/null; fail "setup: fsck -r never claimed a row: $(head -5 "$out")"; }
    echo "$pid $row"
}

# A. SIGTERM: the claim is released on the way out.
read -r PID ROW < <(start_repair)
[ "$(state "$ROW")" = 2 ] || fail "setup: row $ROW is not a repair claim while fsck holds it"
kill -TERM "$PID"; wait "$PID" 2>/dev/null || true
S="$(state "$ROW")"
[ "$S" = 1 ] && pass "A: SIGTERM -- the borrowed row $ROW is a registration again" ||
    fail "A: SIGTERM left row $ROW in state $S (2 = still a repair claim)"

# B. SIGKILL: nothing in the tool runs; the kernel's mount gate watches
# the dead claim for the stale window and gives the row back.
read -r PID ROW < <(start_repair)
kill -9 "$PID"; wait "$PID" 2>/dev/null || true
[ "$(state "$ROW")" = 2 ] || fail "setup: SIGKILL did not leave the claim behind (row $ROW state $(state "$ROW"))"
ct_mount "$DEV" "$MNT" || fail "B: the volume did not mount past a dead repair claim"
S="$(state "$ROW")"
ct_umount "$MNT"
[ "$S" = 1 ] && pass "B: the mount reaped the dead claim and restored row $ROW's registration" ||
    fail "B: after the mount row $ROW is in state $S -- the dead claim was never reaped"
dmesg | tail -20 | grep -q "reaped the dead repair claim on row $ROW" &&
    pass "B: and said so" || fail "B: no reap message in dmesg"

# C. SIGKILL again; this time the next fsck -r reaps it.
read -r PID ROW < <(start_repair)
kill -9 "$PID"; wait "$PID" 2>/dev/null || true
OUT="$(CETRAFS_PEER_PROBE_SECS=3 "$FSCK" -r "$DEV" 2>&1 || true)"
grep -q "registry row $ROW: reaped a dead repair claim and gave the row back" <<<"$OUT" &&
    pass "C: the next fsck -r reaped the dead claim on row $ROW" ||
    fail "C: the next fsck -r did not reap row $ROW: $(grep -i 'repair\|registry' <<<"$OUT" | head -3)"

# D. That same run, with a full registry of departed rows nothing
# references, retired the one it did not borrow.
grep -q "registry full: retired node slot" <<<"$OUT" &&
    pass "D: fsck -r retired a departed, unreferenced row" ||
    fail "D: fsck -r retired nothing on a full registry of departed rows"
FREE=0
for r in 0 1; do [ "$(state $r)" = 0 ] && FREE=$((FREE + 1)); done
[ "$FREE" -ge 1 ] && pass "D: the registry has $FREE free row(s) again" ||
    fail "D: still no free row (states $(state 0)/$(state 1))"
ct_mount "$DEV" "$MNT" && pass "D: and the volume still mounts" || fail "D: the volume no longer mounts"
ct_umount "$MNT"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
