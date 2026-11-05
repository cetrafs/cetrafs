#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs never restamps a damaged record into a valid one
#
# A grow updates two records in place and restamps their checksums: the
# tail Block Group table segment (its `next` link) and each grown Zone
# Group's hot sector (its free count). It checked neither checksum
# first, so a damaged record came out of the grow carrying a valid CRC
# over its damage, and fsck had nothing left to notice (audit L14).
#
# DISCRIMINATION: on the unfixed code both grows exit 0 and fsck finds
# the records valid afterwards.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
CPOKE="$(ct_helper csum_poke)"
SPOKE="$(ct_helper seg_poke)"
GROW="$ROOT/userspace/growfs.cetra"

grow_to() { # <img> <size>: losetup, grow, print rc
    local rc=0 dev
    truncate -s "$2" "$1"
    dev="$(ct_loop "$1")"
    "$GROW" "$dev" >/dev/null 2>&1 || rc=$?
    losetup -d "$dev"
    echo "$rc"
}

# 1. A Zone Group hot sector damaged before a grow that adds to it.
IMG="$(ct_image 600 gvzg)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
"$CPOKE" "$DEV" zg-hot 0 >/dev/null
losetup -d "$DEV"
RC="$(grow_to "$IMG" 1200M)"
DEV="$(ct_loop "$IMG")"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
losetup -d "$DEV"
[ "$RC" != 0 ] && [ "$RC" -lt 128 ] && pass "a damaged Zone Group row: growfs reported it (rc=$RC)" ||
    fail "a damaged Zone Group row: growfs exited $RC"
grep -qiE 'ZG ?0.*(checksum|crc)|zone group 0.*(checksum|crc)' <<<"$OUT" &&
    pass "and left it damaged, for fsck to find" ||
    fail "the damaged Zone Group row came out of the grow with a valid checksum: $(grep -m3 '^ERR' <<<"$OUT")"

# 2. The tail segment of a once-grown volume, damaged before the second grow.
IMG="$(ct_image 600 gvseg)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
losetup -d "$DEV"
[ "$(grow_to "$IMG" 1200M)" = 0 ] || { fail "setup: the first grow failed"; ct_exit; }
DEV="$(ct_loop "$IMG")"
"$SPOKE" "$DEV" crc >/dev/null
losetup -d "$DEV"
RC="$(grow_to "$IMG" 1800M)"
DEV="$(ct_loop "$IMG")"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
losetup -d "$DEV"
[ "$RC" != 0 ] && [ "$RC" -lt 128 ] && pass "a damaged table segment: growfs refused (rc=$RC)" ||
    fail "a damaged table segment: growfs exited $RC"
grep -qiE 'segment.*(checksum|crc)' <<<"$OUT" && pass "and it is still reported damaged" ||
    fail "the damaged segment came out of the grow valid: $(grep -m3 '^ERR' <<<"$OUT")"
ct_exit
