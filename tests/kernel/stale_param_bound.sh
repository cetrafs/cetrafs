#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the stale_secs module parameter refuses a window no peer honours
#
# Peers honour an advertised window of at most 240 s; above it a row
# reads as illegal and is watched for four of its beats instead, and the
# lease, sized from what peers will wait, shrinks with it. The parameter
# took up to 86400 and a mount used it as given: 300 configured, a 45 s
# lease, and "stale_secs: 300" reported everywhere (audit 2026-11-15
# BM-41). Now:
#   1. writing 300 is refused, the value stays as it was;
#   2. 240 is taken, and a mount reports 240.
#
# DISCRIMINATION: stale_param_unbounded=1 -- 300 is taken and a mount
# reports 300.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
IMG="$(ct_image 560 staleparam)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt staleparam)"
ct_track mnt "$MNT"
ct_param_set stale_param_unbounded 0
ct_param_set stale_secs 120
ct_mkfs "$DEV" -z 1 -f >/dev/null

# -> SECS: the stale_secs a mount made now reports
mounted_secs() {
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    SECS="$(sed -n 's/^stale_secs: //p' "$(ct_procdir "$DEV")/controls")"
    ct_umount "$MNT"
}

echo 300 >"$P/stale_secs" 2>/dev/null && fail "1: stale_secs=300 was accepted" ||
    pass "1: stale_secs=300 is refused"
[ "$(cat "$P/stale_secs")" = 120 ] && pass "1: the value stayed 120" || fail "1: the value is $(cat "$P/stale_secs")"

S=refused
echo 240 >"$P/stale_secs" && mounted_secs && S="$SECS"
[ "$S" = 240 ] && pass "2: 240 is taken and a mount reports it" || fail "2: 240 gave $S"

echo 1 >"$P/stale_param_unbounded"
C=refused
echo 300 >"$P/stale_secs" 2>/dev/null && mounted_secs && C="$SECS"
echo 120 >"$P/stale_secs"
echo 0 >"$P/stale_param_unbounded"
[ "$C" = 300 ] && pass "control: as before, 300 was taken and a mount reported it" ||
    fail "control: 300 gave $C -- the suite does not reach the bound"
ct_exit
