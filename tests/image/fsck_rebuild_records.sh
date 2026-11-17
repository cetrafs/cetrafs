#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r rebuilds a damaged Zone Group record, Block Group descriptor or registry row
#
# One damaged global record refused every mount, and fsck could only say
# so and stop (audit 2026-11-15 B-14) -- for a record whose every field
# can be derived. A Zone Group record is rebuilt: its id from its place,
# no owner (nothing is mounted; the next mount claims it), its counts
# recounted from the bitmaps by the same run. A Block Group descriptor
# is rebuilt from the group's own header: in the pool when its bitmap is
# empty, else its round-robin Zone Group (absent a queued free naming
# it), with what its bitmap uses. A registry row is rebuilt as the
# state a crash leaves: a dead node (the next mount reclaims it), or --
# a repair claim -- nothing.
#
# Each case flips one bit inside the checksummed half of a fresh volume
# (nothing is mounted: fsck alone), then:
#   1. fsck without -r: nonzero, names the record, and (a Zone Group
#      record) still checks the rest -- it reaches the namespace walk;
#   2. fsck -r: rebuilds it;
#   3. fsck after it: clean.
#
# DISCRIMINATION: 1 is the control -- without -r nothing is rebuilt and
# the following fsck is still dirty (checked by 3 only after 2). And a
# descriptor whose header is damaged too has no geometry to trust: -r
# must refuse it, not guess.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 rebuild)"
DEV="$(ct_loop "$IMG")"
build() { ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

BG_POKE="$(ct_helper bg_poke)"
WALK=1
EXPECT="rebuilt the record"
# <label> <poke args...>
case_rebuilt() {
    local label="$1" out rc
    shift
    build
    [ -z "${PRE:-}" ] || $PRE
    "$POKE" "$DEV" "$@" >/dev/null
    blockdev --flushbufs "$DEV"
    rc=0
    out="$("$FSCK" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" != 0 ] && grep -q "rebuilds it" <<<"$out" && { [ "$WALK" = 0 ] || grep -q "namespace:" <<<"$out"; }; then
        pass "$label: reported, and the rest of the volume still checked"
    else
        fail "$label: rc=$rc: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
    fi
    "$FSCK" "$DEV" >/dev/null 2>&1 && fail "$label: control -- clean again without a repair" ||
        pass "$label: control -- without -r it stays damaged"
    out="$("$FSCK" -r "$DEV" 2>&1 || true)"
    grep -q "$EXPECT" <<<"$out" && pass "$label: fsck -r rebuilt it" ||
        fail "$label: -r did not rebuild: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
    out="$("$FSCK" "$DEV" 2>&1)" && pass "$label: clean after the rebuild" ||
        fail "$label: still dirty: $(grep -E '^ERR' <<<"$out" | head -3 | tr '\n' ' ')"
}

case_rebuilt "zone group, hot half" zg-hot 1
case_rebuilt "zone group, cold half" zg-cold 0

WALK=0
# Two Block Groups at this size: BG0 holds the root directory's block.
EXPECT="rebuilt the descriptor of BG0: .*owner ZG0, [1-9][0-9]* block(s) in use"
case_rebuilt "block group 0, holding the root" bg-desc 0
EXPECT="rebuilt the descriptor of BG1: .*owner pool"
case_rebuilt "block group 1, empty and last" bg-desc 1
fill1() { "$BG_POKE" "$DEV" 1 0 fill-bitmap >/dev/null; }
PRE=fill1
EXPECT="rebuilt the descriptor of BG1: .*owner ZG1, [1-9][0-9]* block(s) in use"
case_rebuilt "block group 1, holding blocks" bg-desc 1
# A free queued for it in ZG0's queue: only the owner's queue receives
# them, so ZG0 owns it; and its free_gen passes the stamp, so the entry
# -- possibly dead already -- never applies (a leak, which -r reclaims).
PENDING_POKE="$(ct_helper pending_poke)"
queued1() {
    local d
    fill1
    d="$("$BG_POKE" "$DEV" 1 --dump)"
    d=$(($(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d") + $(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d") + 7))
    "$PENDING_POKE" "$DEV" add 0 "$d" 1 5 >/dev/null
}
PRE=queued1
EXPECT="rebuilt the descriptor of BG1: .*owner ZG0, .*free_gen 6"
case_rebuilt "block group 1, a free queued by ZG0" bg-desc 1
PRE=

WALK=1
NODE_POKE="$(ct_helper node_poke)"
reg1() { "$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null; }
claim3() { "$NODE_POKE" "$DEV" 3 2 bb "$(date +%s)" >/dev/null; }
PRE=reg1
EXPECT="rebuilt node slot 1 as a dead node"
case_rebuilt "registry row of a registered node" node 1
PRE=
EXPECT="rebuilt node slot 2 as a dead node"
case_rebuilt "registry row, free and blank" node 2
PRE=claim3
EXPECT="rebuilt node slot 3 as free"
case_rebuilt "registry row of a repair claim" node 3
PRE=
WALK=0

# No verifying header: refused, not guessed.
build
"$POKE" "$DEV" bg-desc 1 >/dev/null
"$POKE" "$DEV" bg-hdr 1 >/dev/null
blockdev --flushbufs "$DEV"
rc=0
out="$("$FSCK" -r "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "not rebuilt" <<<"$out" && ! grep -q "rebuilt the descriptor" <<<"$out" &&
    pass "header damaged too: -r refuses to guess its geometry" ||
    fail "header damaged too: rc=$rc: $(grep -E 'ERR|rebuilt' <<<"$out" | head -3 | tr '\n' ' ')"
ct_exit
