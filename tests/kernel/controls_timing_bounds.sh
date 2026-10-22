#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the operator controls file refuses dangerous cluster timing
#
# hb_interval_secs / stale_secs set the heartbeat lease: how often a node
# proves it is alive, and how long a peer waits before declaring it dead
# and reclaiming its claims. Set too low, a node that merely paused (GC,
# an I/O stall, jitter) is declared dead while still writing -- a
# split-brain window. Set too high, a genuinely crashed node locks up its
# claims far longer than a VM datastore tolerates. And a window shorter
# than a few beats makes one missed tick fatal.
#
# So the per-mount controls file bounds both knobs AND enforces
# stale_secs >= CETRAFS_STALE_MIN_BEATS x hb_interval_secs. (The module
# PARAMS stay unbounded test knobs -- that is how the loop suites compress
# timing; this is only the operator-facing path.)
#
# DISCRIMINATION: each rejection below is paired with the in-range value
# that must be ACCEPTED, so a build that dropped the checks would fail the
# "rejected" assertions, and a build that over-rejected would fail the
# "accepted" ones.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 ctb)"
MNT="$(ct_mnt ctb)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="/proc/fs/cetrafs/$(basename "$DEV")/controls"

# set <key>=<val>, succeeding; returns the write's exit status
setv() { printf '%s=%s\n' "$1" "$2" >"$CTL" 2>/dev/null; }
cur() { grep "^$1:" "$CTL" | awk '{print $2}'; }

# Start from a known-good wide window so ordering never trips us up.
setv stale_secs 240 && setv hb_interval_secs 30 ||
    fail "setup: a valid wide window was refused"

log "in-range values are accepted"
setv hb_interval_secs 5 && [ "$(cur hb_interval_secs)" = "5" ] &&
    pass "hb_interval_secs=5 (floor) accepted" || fail "the floor value was refused"
setv stale_secs 15 && [ "$(cur stale_secs)" = "15" ] &&
    pass "stale_secs=15 (floor, = 3x5) accepted" || fail "a valid floor stale was refused"

log "out-of-range values are refused, and leave the setting unchanged"
B4="$(cur hb_interval_secs)"
setv hb_interval_secs 1 && fail "hb_interval_secs=1 was accepted (too low)" ||
    pass "hb_interval_secs=1 refused"
setv hb_interval_secs 31 && fail "hb_interval_secs=31 was accepted (too high)" ||
    pass "hb_interval_secs=31 refused"
[ "$(cur hb_interval_secs)" = "$B4" ] && pass "a refused write did not change the live value ($B4)" ||
    fail "a refused write changed the value to $(cur hb_interval_secs)"

setv stale_secs 10 && fail "stale_secs=10 was accepted (below the 15s floor)" ||
    pass "stale_secs=10 refused (below floor)"
# The ceiling is 240, deliberately twice the 120 default: a default
# sitting exactly on its ceiling leaves an operator able to lower the
# window but never raise it, and raising is the direction that matters
# (a fabric whose path-retry timeout is longer than ours).
setv stale_secs 240 || fail "stale_secs=240 refused -- that is the ceiling, it must be accepted"
pass "stale_secs=240 accepted (the ceiling itself)"
setv stale_secs 241 && fail "stale_secs=241 was accepted (above the 240 ceiling)" ||
    pass "stale_secs=241 refused (above ceiling)"

log "the stale >= 3 x interval relationship is enforced"
# interval is 5 now (set above); stale=15 is exactly 3x and was accepted.
# stale=14 would be < 3x5 -- but it is also below the 15 floor, so widen
# the beat to make the ratio the discriminating constraint: interval 10,
# then stale 20 (< 3x10=30) must be refused for the RATIO, not the range.
setv stale_secs 60 && setv hb_interval_secs 10 || fail "setup for ratio test failed"
setv stale_secs 20 && fail "stale_secs=20 accepted with interval=10 (20 < 3x10)" ||
    pass "stale_secs=20 refused: below 3x the 10s interval (in range, ratio fails)"
setv stale_secs 30 && [ "$(cur stale_secs)" = "30" ] &&
    pass "stale_secs=30 accepted (exactly 3x the 10s interval)" || fail "stale_secs=30 (=3x10) was refused"
# and the symmetric direction: raising the interval so the current stale
# would fall below 3x must be refused.
setv hb_interval_secs 15 && fail "hb_interval_secs=15 accepted while stale=30 (30 < 3x15)" ||
    pass "hb_interval_secs=15 refused: would leave stale below 3 beats"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck failed"
ct_exit
