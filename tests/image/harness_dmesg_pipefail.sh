#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# dmesg_since piped into grep -q finds a line that is there, under pipefail
#
# Forty-nine suites assert on the kernel log as
#   dmesg_since "$MARK" | grep -q PATTERN
# and every suite runs under `set -o pipefail`. grep -q exits at its
# first match; if dmesg_since still has output to write, it dies of
# SIGPIPE, the pipeline's status becomes 141, and the assertion reads a
# line that IS in the log as missing. Nothing about it is visible: the
# suite simply reports the behaviour it was checking for as absent. The
# more the kernel logs after the mark -- a whole gate's worth, on a
# chatty run -- the likelier.
#
# The test writes more than a pipe buffer of lines after a mark and
# looks for the FIRST of them, which grep finds while the producer is
# still writing.
#
# DISCRIMINATION (measured on the unfixed harness): the match is
# reported as a miss.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

MARK="$(dmesg_mark)"
TOK="ctpipe-$$-$RANDOM"
# ~70 KiB: past a 64 KiB pipe buffer, short of rotating the mark itself
# out of the kernel's log buffer (which would leave nothing to find).
for i in $(seq 1 700); do echo "$TOK line $i $(printf '%080d' 0)" >/dev/kmsg; done
n="$(dmesg_since "$MARK" | grep -c "$TOK" || true)"
[ "$n" -ge 650 ] && pass "setup: $n lines after the mark (well past a pipe buffer)" ||
    { fail "setup: only $n lines reached the log"; ct_exit; }

misses=0
for _ in 1 2 3 4 5; do
    dmesg_since "$MARK" | grep -q "$TOK line 1 " || misses=$((misses + 1))
done
[ "$misses" = 0 ] && pass "dmesg_since | grep -q found the first line 5 times of 5" ||
    fail "dmesg_since | grep -q missed a line that is in the log $misses time(s) of 5"

ct_exit
