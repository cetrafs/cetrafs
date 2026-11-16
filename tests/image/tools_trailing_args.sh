#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs and growfs refuse an argument they do not understand, and write nothing
#
# Both took the device only as argv[1] and silently dropped anything
# after the options: `mkfs.cetra /dev/x 8T` formatted the whole LUN,
# `growfs.cetra /dev/x 3T` grew to the whole device -- irreversibly --
# and `mkfs.cetra -f /dev/x` tried to open "-f" (audit 2026-11-14 M-35,
# BM-62). Each is now refused as a usage error (exit 2) before the
# device is touched.
#
#   1. mkfs <dev> 8T: exit 2, block 0 untouched;
#   2. mkfs -f <dev>: exit 2, names the order;
#   3. growfs <dev> 3T on a volume formatted smaller: exit 2, the
#      volume's size unchanged;
#   control: the same mkfs and growfs without the stray argument run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
MKFS="$ROOT/userspace/mkfs.cetra"
GROWFS="$ROOT/userspace/growfs.cetra"
SBPOKE="$(ct_helper sb_poke)"
export CETRAFS_PEER_PROBE_SECS=3
IMG="$(ct_image 1200 tta)"
DEV="$(ct_loop "$IMG")"
b0() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
total() { "$SBPOKE" "$DEV" | sed -n 's/^total_blocks=//p'; }

BEFORE="$(b0)"
rc=0
"$MKFS" "$DEV" 8T -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ "$(b0)" = "$BEFORE" ] && pass "1: mkfs <dev> 8T: usage error, block 0 untouched" ||
    fail "1: rc=$rc, block 0 $([ "$(b0)" = "$BEFORE" ] && echo untouched || echo WRITTEN)"
rc=0
OUT="$("$MKFS" -f "$DEV" -z 1 -b 512 -J 0 -N 1024 2>&1)" || rc=$?
[ "$rc" = 2 ] && grep -q "device comes first" <<<"$OUT" && pass "2: mkfs -f <dev>: usage error naming the order" ||
    fail "2: rc=$rc: $OUT"

"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -s 600M -f >/dev/null 2>&1 ||
    { fail "control: mkfs without the stray argument failed"; ct_exit; }
T0="$(total)"
[ -n "$T0" ] && [ "$(b0)" != "$BEFORE" ] && pass "control: mkfs without the stray argument formats" ||
    fail "control: mkfs wrote nothing"
rc=0
"$GROWFS" "$DEV" 3T >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ "$(total)" = "$T0" ] && pass "3: growfs <dev> 3T: usage error, the volume's size unchanged" ||
    fail "3: rc=$rc total_blocks $T0 -> $(total)"
"$GROWFS" "$DEV" >/dev/null 2>&1 || true
[ "$(total)" -gt "$T0" ] && pass "control: growfs without the stray argument grows" ||
    fail "control: growfs without the stray argument did not grow ($T0 -> $(total))"
ct_exit
