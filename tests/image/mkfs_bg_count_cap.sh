#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs never lays out more Block Groups than the mount accepts
#
# The mount refuses a volume of more than CETRAFS_MAX_BLOCK_GROUPS (2^20)
# Block Groups, and mkfs did not know: -b 512 on a device past 512 TiB,
# or the 1 GiB default past 1 PiB, wrote a volume no node could mount
# (re-audit of the 2026-11-14 fixes).
#
# A dm-zero device stands in for the LUN, and mkfs runs dry (-n): the
# layout is computed and printed, nothing is written.
#   1. 600 TiB with -b 512 (1.2M groups) is refused, naming -b 600;
#   2. 1.5 PiB with the default size is laid out with at most 2^20 groups.
#
# DISCRIMINATION: run against the unfixed mkfs, case 1 printed a layout
# of 1,228,7xx Block Groups and case 2 one of ~1.5M.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
CT_NEED_MODULE=0
require_root
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }

N1="ctbgcap1-$$"
N2="ctbgcap2-$$"

ct_track dm "$N1"
ct_track dm "$N2"
dmsetup create "$N1" --table "0 $((600 * 1024 * 1024 * 1024 * 2)) zero"
dmsetup create "$N2" --table "0 $((1536 * 1024 * 1024 * 1024 * 2)) zero"
[ -b "/dev/mapper/$N1" ] && [ -b "/dev/mapper/$N2" ] || { fail "setup: the dm-zero devices were not created"; ct_exit; }

rc=0
out="$(ct_mkfs "/dev/mapper/$N1" -b 512 -n -f 2>&1)" || rc=$?
log "600 TiB, -b 512: rc=$rc: $(tail -1 <<<"$out")"
[ "$rc" != 0 ] && grep -q "pass -b 600 or more" <<<"$out" &&
    pass "1: 600 TiB with -b 512 is refused, naming -b 600" ||
    fail "1: mkfs laid out 600 TiB with -b 512 (rc=$rc)"

rc=0
out="$(ct_mkfs "/dev/mapper/$N2" -n -f 2>&1)" || rc=$?
n="$(grep -oE 'BGs: [0-9]+' <<<"$out" | head -1 | grep -oE '[0-9]+' || echo 0)"
log "1.5 PiB, default: rc=$rc, $n Block Groups"
[ "$rc" = 0 ] && [ "$n" -gt 0 ] && [ "$n" -le $((1 << 20)) ] &&
    pass "2: 1.5 PiB with the default size is laid out with $n Block Groups" ||
    fail "2: 1.5 PiB with the default size: rc=$rc, $n Block Groups -- $(tail -2 <<<"$out")"
ct_exit
