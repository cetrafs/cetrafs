#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the Zone Group table chain is format room this build refuses rather than ignores (A-13)
#
# Format 0x000A reserves a Zone Group table chain in the superblock
# (zg_seg_next, zg_first_count) so that adding Zone Groups later needs no
# format change (audit 2026-11-15 A-13). No build appends one yet. A
# volume that has one -- written by a later build, or by damage -- must
# be REFUSED by this one: mounted, it would run without the Zone Groups
# it cannot see, their Block Groups and their pending-free queues, and
# an address field nobody follows is the rule-19 hole.
#
#   1. mkfs writes both fields zero, and the volume mounts;
#   2. zg_first_count equal to zone_group_count is the same table, and
#      mounts and checks clean;
#   3. a chain head, or a first count that differs from the total, is
#      refused by the mount (by THIS check, named in dmesg) and by fsck.
#
# DISCRIMINATION: with the refusal removed from cetrafs_validate_layout(),
# 3's mount succeeds or fails on some other check, not this one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SB_POKE="$(ct_helper sb_poke)"

DEV="$(ct_dev 560 zgroom)"
MNT="$(ct_mnt zgroom)"
ct_track mnt "$MNT"
field() { "$SB_POKE" "$DEV" | sed -n "s/^$1=//p"; }

ct_mkfs_small "$DEV" >/dev/null
Z="$(field zone_group_count)"
[ "$(field zg_seg_next)" = 0 ] && [ "$(field zg_first_count)" = 0 ] &&
    pass "1: mkfs writes no Zone Group chain (head 0, first count 0; $Z Zone Group(s))" ||
    fail "1: mkfs wrote zg_seg_next=$(field zg_seg_next) zg_first_count=$(field zg_first_count)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
pass "1: and it mounts"
ct_umount "$MNT"

"$SB_POKE" "$DEV" zg_first_count "$Z" >/dev/null
ct_mount "$DEV" "$MNT"
echo ok >"$MNT/f"
ct_umount "$MNT"
pass "2: zg_first_count = zone_group_count ($Z) mounts"
ct_fsck "$DEV" >/dev/null && pass "2: and fsck is clean" || fail "2: fsck refuses zg_first_count = zone_group_count"

# <label> <field> <value>: on a fresh volume, the mount and fsck refuse
refused() {
    local mark out
    ct_mkfs_small "$DEV" >/dev/null
    "$SB_POKE" "$DEV" "$2" "$3" >/dev/null
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        fail "3: a volume with $1 mounted"
    elif dmesg_since "$mark" | grep -q "the Zone Group table has appended segments"; then
        pass "3: the mount refuses $1, by the Zone Group chain check"
    else
        fail "3: the mount refused $1, but not by the Zone Group chain check: $(dmesg_since "$mark" | grep cetrafs | tail -1)"
    fi
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    grep -q "^ERR: the Zone Group table has appended segments" <<<"$out" &&
        pass "3: fsck refuses $1" || fail "3: fsck does not refuse $1: $(tail -2 <<<"$out" | tr '\n' ' ')"
}
refused "a chain head" zg_seg_next 4096
refused "a first count past the total" zg_first_count $((Z + 1))
ct_exit
