#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub's interval and confirmation gap are bounded when they are written
#
# scrub_interval_secs and scrub_gap_secs were taken as written. A gap near
# 2^32 made `gap * 10` wrap in the scrub's confirmation loop, so a gap of
# 429496730 waited four passes; an enormous gap parked the scrub for days
# (audit L3, class 39). Both are clamped where they are written, so what
# the module holds -- and what sysfs reads back -- is what it uses:
#
#   gap       1 .. 3600 s     interval  1 .. 86400 s
#
# Zero is a floor, not "off". The gap's floor is the default, 15 s: it is
# a safety window, and root lowering it to 1 s was a finding (L3). The
# suites that drive it to 1-2 s for speed lower the floor first through
# the test parameter scrub_gap_floor_secs.
#
# DISCRIMINATION: with the unbounded parameters the readback is the value
# written (4294967295), and the assertions below fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
[ -w "$P/scrub_gap_secs" ] && [ -w "$P/scrub_interval_secs" ] || { skip "scrub timing parameters are missing"; ct_exit; }
GAP0="$(cat "$P/scrub_gap_secs")"
IVL0="$(cat "$P/scrub_interval_secs")"
restore() { echo "$GAP0" >"$P/scrub_gap_secs" 2>/dev/null || true; echo "$IVL0" >"$P/scrub_interval_secs" 2>/dev/null || true; }

# put <param> <value>: write, then echo what the module now holds
put() { echo "$2" >"$P/$1" 2>/dev/null || true; cat "$P/$1"; }

[ "$(put scrub_gap_secs 4294967295)" = 3600 ] &&
    pass "an enormous gap is held at the 3600 s ceiling" ||
    fail "a gap of 4294967295 is held as $(cat "$P/scrub_gap_secs") (wraps the confirmation loop)"
[ "$(put scrub_gap_secs 429496730)" = 3600 ] &&
    pass "a gap whose x10 wraps is held at the ceiling, not the wrapped value" ||
    fail "a gap of 429496730 is held as $(cat "$P/scrub_gap_secs")"
# The gap is a safety window: its floor is the default, 15 s, and only
# the test parameter lowers it (audit 2026-11-14 L3, class 39).
[ "$(put scrub_gap_secs 0)" = 15 ] && pass "a gap of 0 is held at the 15 s floor" ||
    fail "a gap of 0 is held as $(cat "$P/scrub_gap_secs")"
[ "$(put scrub_gap_secs 1)" = 15 ] && pass "a gap of 1 s, below the safety floor, is held at 15 s" ||
    fail "a gap of 1 is held as $(cat "$P/scrub_gap_secs") -- root can shrink the safety window"
[ "$(put scrub_gap_secs 20)" = 20 ] && pass "control: an in-range gap is held as written" ||
    fail "control: a gap of 20 is held as $(cat "$P/scrub_gap_secs")"
ct_param_set scrub_gap_floor_secs 1
[ "$(put scrub_gap_secs 2)" = 2 ] && pass "control: with the test floor lowered, a 2 s gap is held as written" ||
    fail "control: a gap of 2 under the test floor is held as $(cat "$P/scrub_gap_secs")"

[ "$(put scrub_interval_secs 4294967295)" = 86400 ] &&
    pass "an enormous interval is held at the one-day ceiling" ||
    fail "an interval of 4294967295 is held as $(cat "$P/scrub_interval_secs")"
[ "$(put scrub_interval_secs 0)" = 1 ] && pass "an interval of 0 is held at the 1 s floor" ||
    fail "an interval of 0 is held as $(cat "$P/scrub_interval_secs")"
[ "$(put scrub_interval_secs 30)" = 30 ] && pass "control: an in-range interval is held as written" ||
    fail "control: an interval of 30 is held as $(cat "$P/scrub_interval_secs")"

echo notanumber >"$P/scrub_gap_secs" 2>/dev/null || true
[ "$(cat "$P/scrub_gap_secs")" = 2 ] &&
    pass "a non-numeric gap is refused and the held value stays" ||
    fail "a non-numeric gap changed the held value"
restore
ct_exit
