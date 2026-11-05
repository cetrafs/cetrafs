#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the heartbeat and stale-window module params reach a mount bounded and traced
#
# hb_interval_secs and stale_secs are test knobs -- suites compress the
# timing far below what the controls file allows an operator -- but they
# were plain parameters: untraced, and taken by every later mount as
# written. stale_secs=0 judged every peer dead at the floor of its
# advertised interval, the split-brain lever the TEST ONLY tracing exists
# for, and a large hb_interval_secs overflowed `secs * 1000` (audit
# 2026-11-05, N5).
#
# Now a write is logged as a TEST ONLY knob, and a mount takes the value
# clamped: 0/0 becomes a 1 s beat and a 3 s window; an overflowing beat
# and window become 3600 s and 86400 s.
#
# DISCRIMINATION: proven 2026-11-05 with the old plain parameters and
# unclamped seeding: no TEST ONLY line, and the mount reports
# stale_secs 0 and the overflowing beat as written.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 tpb)"
MNT="$(ct_mnt tpb)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
PROC=""
info() { sed -n "s/^$1: //p" "$PROC/controls"; }

MARK="$(dmesg_mark)"
ct_param_set stale_secs 0
ct_param_set hb_interval_secs 0
dmesg_since "$MARK" | grep -q "TEST ONLY parameter stale_secs" &&
    pass "a write to stale_secs is traced as a TEST ONLY knob" ||
    fail "a write to stale_secs left no TEST ONLY trace"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
[ "$(info stale_secs)" = 3 ] && pass "stale_secs=0 reaches the mount as the 3 s floor" ||
    fail "stale_secs=0 reached the mount as $(info stale_secs)"
[ "$(info hb_interval_secs)" = 1 ] && pass "hb_interval_secs=0 reaches the mount as 1 s" ||
    fail "hb_interval_secs=0 reached the mount as $(info hb_interval_secs)"
ct_umount "$MNT"

ct_param_set stale_secs 4294967295
ct_param_set hb_interval_secs 4294967
ct_mount "$DEV" "$MNT"
[ "$(info hb_interval_secs)" = 3600 ] && pass "an overflowing hb_interval_secs is capped at 3600" ||
    fail "hb_interval_secs=4294967 reached the mount as $(info hb_interval_secs)"
[ "$(info stale_secs)" = 86400 ] && pass "an enormous stale_secs is capped at 86400" ||
    fail "stale_secs=4294967295 reached the mount as $(info stale_secs)"
ct_umount "$MNT"
ct_exit
