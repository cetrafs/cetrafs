#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the live-peer probe watches long enough for a peer's own advertised heartbeat interval
#
# mkfs -f, fsck and fsck -r decide "nobody has this volume mounted" by
# watching every live-looking Node Registry row for one probe window and
# seeing its hb_seq stand still. The window was fixed at one DEFAULT
# interval + 5 s (20 s), but a node may legally run a slower interval
# -- up to 30 s, set through procfs controls -- and advertises it in its
# row. A node beating every 30 s can sit through a 20 s probe without a
# beat and be declared gone; the comment at the constant said the
# window "must exceed one full heartbeat interval", and it did not.
#
# The test compresses the base window (CETRAFS_PEER_PROBE_SECS=4) and
# poses as a peer advertising an 8 s interval and beating every 7 s --
# the same shape at a scale a suite can afford. The probe must outlast
# the advertised interval and find it.
#
# DISCRIMINATION (measured on the unfixed code): fsck watches 4 s,
# sees no beat, and checks a volume a live node is writing.
#
# No kernel module and nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 slowpeer)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

"$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" 8 >/dev/null
grep -q 'hb_interval=8' <<<"$("$NODE_POKE" "$DEV" 1)" && pass "a peer row advertising an 8 s heartbeat interval" ||
    { fail "setup: the row does not advertise its interval: $("$NODE_POKE" "$DEV" 1)"; ct_exit; }
blockdev --flushbufs "$DEV"

export CETRAFS_PEER_PROBE_SECS=4
beat() {
    for _ in 1 2 3 4 5; do
        "$NODE_POKE" "$DEV" 1 --beat >/dev/null 2>&1 || true
        sleep 7
    done
}
beat &
BEATER=$!
sleep 0.5 # just past a beat: a 4 s window then sees none
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
unset CETRAFS_PEER_PROBE_SECS

if grep -q "is mounted by another node (registry row 1" <<<"$OUT"; then
    pass "fsck watched long enough to see the slow peer beat, and refused"
elif grep -q "cetrafs fsck: OK" <<<"$OUT"; then
    fail "fsck declared the volume unused and checked it while a node beating every 7 s had it mounted"
else
    fail "fsck failed, but not because of the peer: $(tail -1 <<<"$OUT")"
fi
w="$(sed -n 's/.*watching for \([0-9]*\)s.*/\1/p' <<<"$OUT" | head -1)"
[ -n "$w" ] && [ "$w" -ge 8 ] && pass "the probe window ($w s) covers the advertised interval" ||
    fail "the probe window was ${w:-?} s against an advertised 8 s interval"

ct_exit
