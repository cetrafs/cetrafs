#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs clears a backup GPT at the end of the device
#
# A GPT keeps a backup header and entry array in the device's last 33
# sectors. mkfs overwrote the primary copy and left the backup, and a
# partitioning tool that finds a valid backup behind a damaged primary
# uses it -- and offers to write it back over block 0, the superblock
# (audit 2026-11-14 M-34). mkfs now clears a backup header it finds.
#
# A device with a real GPT (sgdisk), formatted with mkfs -f:
#   1. the last sector no longer holds a GPT header;
#   2. sgdisk finds no backup table to regenerate the primary from;
#   3. the volume is clean (fsck).
#
# DISCRIMINATION: CETRAFS_TEST_MKFS_KEEP_GPT=1 (the backup left, as
# before): sgdisk regenerates the table from the backup.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
command -v sgdisk >/dev/null || { skip "no sgdisk"; ct_exit; }
MKFS="$ROOT/userspace/mkfs.cetra"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <keep 0|1> -> RES
round() {
    local img dev sz tail tbl fsck_rc
    img="$(ct_image 560 "mbg$1")"
    dev="$(ct_loop "$img")"
    sgdisk -o -n 1:0:0 "$dev" >/dev/null 2>&1 || { fail "setup: sgdisk could not write a GPT"; ct_exit; }
    sz="$(blockdev --getsize64 "$dev")"
    [ "$(dd if="$dev" bs=512 skip=$((sz / 512 - 1)) count=1 iflag=direct status=none | head -c 8)" = "EFI PART" ] ||
        { fail "setup: no backup GPT header at the last sector"; ct_exit; }
    if [ "$2" = 1 ]; then
        CETRAFS_TEST_MKFS_KEEP_GPT=1 "$MKFS" "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1
    else
        "$MKFS" "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1
    fi
    tail="$(dd if="$dev" bs=512 skip=$((sz / 512 - 1)) count=1 iflag=direct status=none | head -c 8 | tr -c 'A-Z ' '.')"
    # sgdisk regenerates the main header from a valid backup and says so
    tbl="$(sgdisk -p "$dev" 2>&1 | grep -c 'valid backup\|loaded backup' || true)"
    fsck_rc=0
    "$FSCK" "$dev" >/dev/null 2>&1 || fsck_rc=$?
    RES="tail=$([ "$tail" = "EFI PART" ] && echo gpt || echo none) table=$tbl fsck=$fsck_rc"
}

round c 1
C="$RES"
log "control (backup left): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get tail "$R")" = none ] && pass "1: the last sector no longer holds a GPT header" || fail "1: $R"
[ "$(get table "$R")" = 0 ] && pass "2: sgdisk finds no backup table to restore" || fail "2: $R"
[ "$(get fsck "$R")" = 0 ] && pass "3: the volume is clean" || fail "3: $R"
[ "$(get table "$C")" -ge 1 ] && pass "control: with the backup left, sgdisk regenerates the table from it" ||
    fail "control: no table without the fix -- the suite does not show the hazard: $C"
ct_exit
