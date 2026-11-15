#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs gives every node that may write a Zone Group, or says it did not
#
# A Zone Group is owned by one node at a time and a node allocates only
# from groups it owns. mkfs defaulted to 16 Zone Groups and 64 registry
# rows (-M), silently: hosts 17 and up of a default volume mounted
# cleanly and failed their first allocating write ENOSPC, a reformat to
# fix (audit 2026-11-14 A-13). -z now defaults to the larger of 16 and
# -M, and a volume left with fewer Zone Groups than nodes is warned
# about on stderr.
#   1. no -z, default -M, a device that backs 64: 64 Zone Groups, no warning;
#   2. no -z, -M 8: 16, no warning;
#   3. -z 4 (default -M): warned, "at most 4";
#   4. no -z, a device that backs only a few Block Groups: warned, "at most <that>".
#
# DISCRIMINATION: the old default gives 16 in 1, and no warning in 3 or 4.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
suite "mkfs Zone Group default and warning"
ERR="$(ct_tmp mzd-err)"

# <MiB> [mkfs args...] -> the Zone Group count mkfs reports; stderr in $ERR
zgs() {
    local mb="$1" loop
    shift
    loop="$(ct_loop "$(ct_image "$mb" "mzd$mb")")"
    ct_mkfs "$loop" -f -n "$@" 2>"$ERR" | sed -n 's/^  ZGs: \([0-9]*\),.*/\1/p'
}

Z="$(zgs 40960 -b 512)"
[ "$Z" = 64 ] && ! grep -q "^warning: .*Zone Group" "$ERR" && pass "1: no -z: 64 Zone Groups for the 64 registry rows, no warning" ||
    fail "1: no -z, -M 64: ${Z:-?} Zone Groups ($(cat "$ERR"))"
Z="$(zgs 40960 -b 512 -M 8)"
[ "$Z" = 16 ] && ! grep -q "^warning: .*Zone Group" "$ERR" && pass "2: -M 8: 16 Zone Groups, no warning" ||
    fail "2: -M 8: ${Z:-?} Zone Groups ($(cat "$ERR"))"
Z="$(zgs 40960 -b 512 -z 4)"
[ "$Z" = 4 ] && grep -q "at most 4 node(s) can ever write" "$ERR" && pass "3: -z 4 under -M 64: warned" ||
    fail "3: -z 4: ${Z:-?} Zone Groups, stderr: $(cat "$ERR")"
Z="$(zgs 2200 -b 512)"
[ -n "$Z" ] && [ "$Z" -lt 16 ] && grep -q "at most $Z node(s) can ever write" "$ERR" &&
    pass "4: a device backing only $Z Block Groups: warned" ||
    fail "4: small device: ${Z:-?} Zone Groups, stderr: $(cat "$ERR")"
ct_exit
