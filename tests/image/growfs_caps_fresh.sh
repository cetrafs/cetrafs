#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs's node-readiness notice reads the registry past this host's cache
#
# Before a grow, growfs lists every registered node and flags each whose
# module predates a grown layout (caps without LIVE_GROW). It read the
# rows on a fresh fd -- which shares this host's page cache -- with no
# drop, so a node that registered from another host after the cache
# filled was not listed, and the notice called every node ready (a
# sibling of audit 2026-11-14 U1, BUG-CLASSES class 57).
#
# The registry is read through the device (this host's cache now holds
# it), then a not-ready node is registered straight into the backing
# file -- the loop device's cache is not told, as with a peer on another
# host -- and the scan growfs's notice is built from runs again
# (tests/helpers/caps_scan_probe.c: through growfs the live-peer probe
# re-reads the registry first, which narrows the window to the seconds
# between the two but hides it from a test).
#   1. the scan lists the late node, with caps 0.
#
# DISCRIMINATION: CETRAFS_TEST_CAPS_CACHED skips the drop; the late node
# is then missing from the scan.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"
# Built here, not through ct_helper: the property lives in devutil.h,
# which ct_helper's rebuild check does not look at.
PROBE="$(ct_tmp capsfresh-probe)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$PROBE" "$CT_TESTS/helpers/caps_scan_probe.c" || { fail "setup: the probe does not build"; ct_exit; }
OLD=$(($(date +%s) - 86400))

IMG="$(ct_image 560 capsfresh)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
blockdev --flushbufs "$DEV"
# Held open for the whole suite: the last close of a block device drops
# its page cache, so a scan from a fresh process would start clean. In
# growfs the device is held -- by growfs itself, and in a live grow by
# the mount -- and the cache survives between the reads.
exec 7<"$DEV"

# <cached 0|1> -> the probe's rows. Each round: fill this host's cache
# with the registry, then register a not-ready node in the backing file.
probe() {
    local out
    "$NODE_POKE" "$IMG" 2 0 00 0 >/dev/null # free again
    blockdev --flushbufs "$DEV"
    out="$("$PROBE" "$DEV")" # read through the device: the cache now holds the registry
    grep -q "latepeer" <<<"$out" && { echo "SETUP-STALE"; return; }
    "$NODE_POKE" "$IMG" 2 1 cc "$OLD" >/dev/null
    "$NODE_POKE" "$IMG" 2 --label0 latepeer >/dev/null
    "$NODE_POKE" "$IMG" 2 --caps 0 >/dev/null
    if [ "$1" = 1 ]; then
        CETRAFS_TEST_CAPS_CACHED=1 "$PROBE" "$DEV" 2>/dev/null
    else
        "$PROBE" "$DEV"
    fi
}

OUT="$(probe 0)"
[ "$OUT" != SETUP-STALE ] || { fail "setup: row 2 was not free before the round"; ct_exit; }
grep -q "^row=2 label=latepeer caps=0x0$" <<<"$OUT" &&
    pass "1: the node registered past this host's cache is listed, not ready (caps 0)" ||
    fail "1: the late node is missing from the scan: $(echo $OUT)"

OUT="$(probe 1)"
[ "$OUT" != SETUP-STALE ] || { fail "setup: row 2 was not free before the control round"; ct_exit; }
grep -q "latepeer" <<<"$OUT" &&
    fail "control: the cached scan still saw the late node -- the suite cannot tell" ||
    pass "control: read through the cache, the late node is missing -- the suite discriminates"
exec 7<&-
ct_exit
