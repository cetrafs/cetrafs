#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live node's registry row read with a bad checksum is re-read, not taken for "nobody"
#
# mkfs -f, fsck and fsck -r decide whether another node has the volume
# mounted by finding REGISTERED rows and watching their heartbeat. A row
# whose checksum did not verify was skipped on the first read -- so a
# live node's row caught mid-update counted as no node at all, and with
# no other candidate the tool went ahead on a mounted volume. A checksum
# detects; a reader that runs lockless next to a writer must re-read
# before it concludes anything (CLAUDE.md, rule 3).
#
# The suite poses as a live peer whose row reads torn for the first
# 200 ms and then beats every second. fsck must find it and refuse.
#
# DISCRIMINATION (measured on the unfixed code): fsck sees no candidate
# and checks the volume.
#
# No kernel module and nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 tornrow)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

"$NODE_POKE" "$DEV" 1 1 dd "$(date +%s)" 1 >/dev/null
"$NODE_POKE" "$DEV" 1 --badsum >/dev/null
blockdev --flushbufs "$DEV"

export CETRAFS_PEER_PROBE_SECS=3
beat() {
    sleep 0.2 # the row reads torn until here
    for _ in $(seq 1 10); do
        "$NODE_POKE" "$DEV" 1 --beat >/dev/null 2>&1 || true
        sleep 1
    done
}
beat &
BEATER=$!
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
unset CETRAFS_PEER_PROBE_SECS

grep -q "is mounted by another node (registry row 1" <<<"$OUT" &&
    pass "fsck re-read the torn row, watched the node beat, and refused" ||
    fail "fsck did not refuse a volume a live node has mounted: $(tail -1 <<<"$OUT")"

log "a row torn for longer than the settle budget, then beating, is still a live node"
# The settle loop gives a row ~310 ms. A REGISTERED row still torn after
# that was dropped as garbage before the probe window even started, so
# a node whose row stayed torn a little longer counted as nobody. It is
# now watched through the window, and a row that turns valid in it was
# being written by somebody.
"$NODE_POKE" "$DEV" 1 --beat >/dev/null
"$NODE_POKE" "$DEV" 1 --badsum >/dev/null
blockdev --flushbufs "$DEV"
export CETRAFS_PEER_PROBE_SECS=3
beat_late() {
    sleep 1.5 # well past the 310 ms settle budget
    for _ in $(seq 1 10); do
        "$NODE_POKE" "$DEV" 1 --beat >/dev/null 2>&1 || true
        sleep 1
    done
}
beat_late &
BEATER=$!
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
unset CETRAFS_PEER_PROBE_SECS
grep -q "is mounted by another node (registry row 1" <<<"$OUT" &&
    pass "a row torn past the settle budget that then beats is found, and fsck refuses" ||
    fail "fsck went ahead although the row turned valid and beat during the probe: $(tail -1 <<<"$OUT")"

log "a row that stays bad is garbage and must not block the tools"
"$NODE_POKE" "$DEV" 1 --beat >/dev/null   # a valid row first: --badsum flips the checksum,
"$NODE_POKE" "$DEV" 1 --badsum >/dev/null # so applied twice it would be valid again
blockdev --flushbufs "$DEV"
# It costs one probe window now (it might still turn valid), never a
# refusal: with the window at 3 s, fsck must be done well inside 10.
export CETRAFS_PEER_PROBE_SECS=3
t0=$SECONDS
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
unset CETRAFS_PEER_PROBE_SECS
# fsck then checks the volume and reports the bad slot as damage -- the
# point is that it gets to.
! grep -q "is mounted by another node" <<<"$OUT" && grep -q "node slot 1 CRC mismatch" <<<"$OUT" &&
    [ $((SECONDS - t0)) -le 10 ] &&
    pass "a row that never verifies does not block fsck, which reports it ($((SECONDS - t0)) s)" ||
    fail "a garbage row blocked fsck or slowed it ($((SECONDS - t0)) s): $(tail -1 <<<"$OUT")"
ct_exit
