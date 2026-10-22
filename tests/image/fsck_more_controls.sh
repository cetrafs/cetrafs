#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the fsck detections that had no negative control
#
# Every detection fsck claims needs one of these, or it can silently
# stop working: a check that no longer fires looks exactly like a
# healthy volume. These are the ones left after the checksum, layout,
# cluster-metadata and structural suites -- mostly faults only a
# malformed mkfs or a half-written structure could produce, which is
# precisely why nothing else reaches them.
#
# No module, nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
NPOKE="$(ct_helper node_poke)"
BGPOKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 more)"
DEV="$(ct_loop "$IMG")"
build() { ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

# Run fsck and require it to fail FOR THE STATED REASON. "Failed" alone
# proves nothing: an earlier, more specific check often fires first and
# the one under test never runs.
expect_caught() { # label, regex, command...
    local label="$1" want="$2"; shift 2
    build
    "$@" >/dev/null 2>&1
    # The pokes write the backing file while fsck reads through the loop
    # device, which caches its own copy.
    blockdev --flushbufs "$DEV"
    local out rc=0
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = "0" ]; then
        fail "$label: fsck called the volume CLEAN"
    elif echo "$out" | grep -qE "$want"; then
        pass "$label: detected"
    else
        fail "$label: failed for a different reason -- wanted /$want/, got: $(echo "$out" | grep -E '^(ERR|WARN)' | head -2 | tr '\n' ' ')"
    fi
}

log "a healthy volume passes first"
build
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "the control image is clean before anything is poked" ||
    fail "a freshly-made image is already reported corrupt"

log "a superblock describing more volume than the device holds"
# Every region is internally consistent and the CRC is correct; the
# volume simply claims blocks that do not exist, so anything allocated
# near the end would be written past the device. The kernel refuses to
# mount this, and fsck used to call it clean -- leaving an operator
# with a filesystem that will not mount and a checker that says nothing
# is wrong.
expect_caught "total_blocks larger than the device" "claims .* blocks but the device holds" \
    "$SBPOKE" "$DEV" total_blocks 99999999

log "a feature bit this build does not implement"
# An INCOMPAT bit means "refuse rather than guess". The volume is
# otherwise perfect, which is the point: the only thing wrong is that
# some other implementation wrote structures this one would misread.
expect_caught "an unknown features_incompat bit" "incompat|feature|unsupported|unknown" \
    "$SBPOKE" "$DEV" features_incompat 0x40000000

log "a Node Registry row in a state that does not exist"
# The registry decides who is alive, who may reclaim a Zone Group, and
# which read-presence bit belongs to whom. A row in an unrecognized
# state is one no liveness decision can be made about.
expect_caught "a row with an unrecognized state" "unrecognized state" \
    "$NPOKE" "$DEV" 1 7 ab 12345

log "a Zone Group aggregate that disagrees with its Block Groups"
# The aggregate is what cetrafs_zg_claim_one_more() ranks candidates on
# and what statfs reports. Poking a BG's cached count WITHOUT sync-zg
# leaves the ZG's sum stale, which is exactly the drift an unclean crash
# produces -- and exactly why the old cache-vs-cache structural check
# ("!= sum of its BGs") was removed: it declared that legal
# crash state fatally unrepairable. The CONTENT pass now catches the same
# poke against the bitmap truth (and -r can repair it; see
# fsck_count_convergence.sh).
expect_caught "ZG aggregate vs the sum of its BGs" "free_data_blocks .* != .* actually free" \
    "$BGPOKE" "$DEV" 0 12345

ct_exit
