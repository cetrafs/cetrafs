#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r writes nothing once a node has appeared under its claim
#
# The repair claim's timer watches the registry and raises a flag when a
# node beats under the claim, or the claim is taken (repair_watches_nodes.sh).
# fsck read that flag only in its heartbeat, which four loops call; the
# block group pass -- bitmaps, descriptors, Zone Group counts -- runs
# between two of them, and wrote on after the flag was up, under a node
# that may be mounted. Every repair write now asks first.
#
# Staged: a Block Group's cached free count is made wrong, so the pass
# has a descriptor to rewrite; fsck -r is held just before that pass
# (CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS) while this node's departed
# row beats, as a mount that got past the gate would. The descriptor must
# still carry the wrong count afterwards.
#
# CONTROL: the same run with no beat repairs the count.
# DISCRIMINATION: proven by removing the check from pwrite_all(): the
# descriptor is rewritten after the node appeared, and fsck stops only
# at the next heartbeat.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
BGPOKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 600 fwlc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fwlc)"
ct_mkfs "$DEV" -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo data >"$MNT/f"
ct_umount "$MNT"

bg0_free() { "$MAP" "$DEV" | sed -n 's/^bg 0 .* free=\([0-9]*\)\/.*/\1/p'; }
TRUE_FREE="$(bg0_free)"
[ -n "$TRUE_FREE" ] && [ "$TRUE_FREE" -gt 10 ] || { fail "setup: could not read BG0's free count ($TRUE_FREE)"; ct_exit; }
WRONG=$((TRUE_FREE - 7))

# run <out> <beat:0|1>: fsck -r held before the BG pass; with beat=1,
# row NID beats during the hold. Echoes fsck's rc.
run() {
    local out="$1" beat="$2" pid i rc=0
    "$BGPOKE" "$DEV" 0 "$WRONG" >/dev/null
    CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS=10 "$FSCK" -r "$DEV" >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 150); do
        grep -q "holding before the block group pass" "$out" && break
        sleep 0.2
    done
    grep -q "holding before the block group pass" "$out" || { kill -9 "$pid"; fail "setup: fsck never reached the hold: $(tail -3 "$out")"; ct_exit; }
    if [ "$beat" = 1 ]; then
        "$NPOKE" "$DEV" "$NID" --beat >/dev/null
        sleep 5
        "$NPOKE" "$DEV" "$NID" --beat >/dev/null
    fi
    wait "$pid" || rc=$?
    echo "$rc"
}

O="$(ct_tmp fwlc-out)"
RC="$(run "$O" 0)"
F="$(bg0_free)"
log "control: rc=$RC, BG0 free $WRONG -> $F (true $TRUE_FREE)"
[ "$F" = "$TRUE_FREE" ] && pass "control: with no node beating the pass repairs the count (rc $RC)" ||
    { fail "control: the pass did not repair BG0's count ($F, want $TRUE_FREE): $(grep -m2 ERR "$O")"; ct_exit; }

RC="$(run "$O" 1)"
F="$(bg0_free)"
log "beat: rc=$RC, BG0 free $F; $(grep -m1 'while it is being repaired' "$O" || true)"
grep -q "a node is mounted on this volume while it is being repaired" "$O" && [ "$RC" -gt 1 ] &&
    pass "fsck -r stopped when a node beat under its claim (rc $RC)" ||
    fail "fsck -r did not stop (rc $RC): $(tail -2 "$O")"
[ "$F" = "$WRONG" ] && pass "and wrote nothing after the node appeared (BG0 still $F)" ||
    fail "fsck -r rewrote BG0's descriptor after a node appeared under its claim ($WRONG -> $F)"

"$BGPOKE" "$DEV" 0 "$TRUE_FREE" >/dev/null
ct_exit
