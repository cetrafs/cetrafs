#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck finds an extent's Block Group by binary search, with the same answers
#
# fsck asked "which Block Group holds this block?" by scanning every
# group, once per extent and once per queued block: billions of
# comparisons at 64 TiB (audit 2026-11-14 U9). The ranges are now sorted
# once and searched; a layout whose ranges overlap keeps the scan.
#
# A volume of ~128 Block Groups gets one file spanning most of them; fsck
# runs indexed and with the scan forced (CETRAFS_FSCK_BG_LINEAR=1):
#   1. both report exactly the same;
#   2. indexed, a lookup takes at most 10 steps (log2 of the groups).
#
# DISCRIMINATION: the forced scan takes far more steps per lookup.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 65536 fbgl)" # sparse; a Block Group is at least 512 MiB
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fbgl)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
fallocate -l 60G "$MNT/big" # one extent per Block Group it spans
ct_umount "$MNT"

OUT1="$(ct_tmp fbgl-1)"
OUT0="$(ct_tmp fbgl-0)"
set +e
CETRAFS_FSCK_STATS=1 "$FSCK" "$DEV" >"$OUT1" 2>"$OUT1.err"
R1=$?
CETRAFS_FSCK_STATS=1 CETRAFS_FSCK_BG_LINEAR=1 "$FSCK" "$DEV" >"$OUT0" 2>"$OUT0.err"
R0=$?
set -e
S1="$(grep '^fsck: bg lookups' "$OUT1.err" || true)"
S0="$(grep '^fsck: bg lookups' "$OUT0.err" || true)"
log "indexed: exit $R1, $S1"
log "scan:    exit $R0, $S0"
read -r L1 T1 G1 <<<"$(echo "$S1" | awk '{print $4, $6, $8}')"
read -r L0 T0 _ <<<"$(echo "$S0" | awk '{print $4, $6, $8}')"
[ "${G1:-0}" -ge 100 ] && [ "${L1:-0}" -ge 100 ] ||
    { fail "setup: $G1 groups, $L1 lookups -- not the many-group, many-extent volume this needs"; ct_exit; }
[ "$R1" = "$R0" ] && cmp -s "$OUT1" "$OUT0" &&
    pass "1: indexed and scanned fsck report the same (exit $R1)" ||
    fail "1: indexed and scanned fsck disagree (exit $R1 vs $R0)"
[ "$T1" -le $((L1 * 10)) ] && pass "2: indexed, $L1 lookups took $T1 steps (<= 10 each)" ||
    fail "2: indexed, $L1 lookups took $T1 steps -- not a binary search"
[ "$T0" -gt $((L0 * 20)) ] && [ "$T0" -gt $((T1 * 4)) ] && pass "control: the scan takes $T0 steps for $L0 lookups -- the suite discriminates" ||
    fail "control: the scan took only $T0 steps for $L0 lookups -- the suite cannot tell"
ct_exit
