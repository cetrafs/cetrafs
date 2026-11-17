#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r rebuilds a damaged Zone Group record
#
# One damaged global record refused every mount, and fsck could only say
# so and stop (audit 2026-11-15 B-14) -- for a record whose every field
# can be derived. A Zone Group record is rebuilt: its id from its place,
# no owner (nothing is mounted; the next mount claims it), its counts
# recounted from the bitmaps by the same run.
#
# Each case flips one bit inside the checksummed half of a fresh volume
# (nothing is mounted: fsck alone), then:
#   1. fsck without -r: nonzero, names the record, and still checks the
#      rest (it reaches the namespace walk);
#   2. fsck -r: rebuilds it;
#   3. fsck after it: clean.
#
# DISCRIMINATION: 1 is the control -- without -r nothing is rebuilt and
# the following fsck is still dirty (checked by 3 only after 2).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 rebuild)"
DEV="$(ct_loop "$IMG")"
build() { ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

# <label> <poke args...>
case_rebuilt() {
    local label="$1" out rc
    shift
    build
    "$POKE" "$DEV" "$@" >/dev/null
    blockdev --flushbufs "$DEV"
    rc=0
    out="$("$FSCK" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" != 0 ] && grep -q "rebuilds it" <<<"$out" && grep -q "namespace:" <<<"$out"; then
        pass "$label: reported, and the rest of the volume still checked"
    else
        fail "$label: rc=$rc: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
    fi
    "$FSCK" "$DEV" >/dev/null 2>&1 && fail "$label: control -- clean again without a repair" ||
        pass "$label: control -- without -r it stays damaged"
    out="$("$FSCK" -r "$DEV" 2>&1 || true)"
    grep -q "rebuilt the record" <<<"$out" && pass "$label: fsck -r rebuilt it" ||
        fail "$label: -r did not rebuild: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
    out="$("$FSCK" "$DEV" 2>&1)" && pass "$label: clean after the rebuild" ||
        fail "$label: still dirty: $(grep -E '^ERR' <<<"$out" | head -3 | tr '\n' ' ')"
}

case_rebuilt "zone group, hot half" zg-hot 1
case_rebuilt "zone group, cold half" zg-cold 0
ct_exit
