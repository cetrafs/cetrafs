#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# writing a TEST ONLY module parameter is logged and taints the kernel
#
# Over a hundred module parameters exist only for the suites: each one
# removes or bends a safety check (the reader rule, the journal guard,
# the fence) for every mount, and all are root-writable at run time,
# because the suites flip them on a live mount. One `echo 1 >` on a
# production host used to leave no trace at all (audit R23). A write now
# names the knob and its value in dmesg and taints the kernel
# (TAINT_USER, bit 6), so a volume damaged there says so in every later
# report. source_invariants.sh checks that every such knob is declared
# this way; this checks that the declaration does what it says.
#
# CONTROL: an ordinary tunable (auto_defrag) logs nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
KNOB=fence_peer_fail
[ -w "/sys/module/cetrafs/parameters/$KNOB" ] || { skip "$KNOB is missing"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set auto_defrag "$(cat /sys/module/cetrafs/parameters/auto_defrag)"
dmesg_since "$MARK" | grep -q "TEST ONLY parameter auto_defrag" &&
    fail "control: an ordinary tunable was reported as a test knob" ||
    pass "control: writing an ordinary tunable logs nothing"

T0="$(cat /proc/sys/kernel/tainted)"
MARK="$(dmesg_mark)"
ct_param_set "$KNOB" 0
dmesg_since "$MARK" | grep -q "TEST ONLY parameter $KNOB set to '0'" &&
    pass "writing $KNOB is logged, with its value" ||
    fail "writing $KNOB left no trace in dmesg"
# TAINT_USER never clears, so once any earlier suite of this boot wrote a
# knob the bit cannot discriminate; the log line above is the proof then.
T="$(cat /proc/sys/kernel/tainted)"
if [ $((T0 & 64)) -ne 0 ]; then
    log "the kernel was already tainted (TAINT_USER) before this write; the bit proves nothing here"
fi
[ $((T & 64)) -ne 0 ] && pass "the kernel is tainted (TAINT_USER): tainted=$T" ||
    fail "the kernel is not tainted after a test knob was written (tainted=$T)"
ct_exit
