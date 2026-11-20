#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount refuses Block Groups that overlap or run out of order
#
# The mount checked each Block Group descriptor on its own -- its
# checksum, its geometry, its distance from the descriptor table
# segments -- and never against the group before it. Two checksum-valid
# descriptors naming the same blocks mounted, and both bitmaps handed
# those blocks out: two files on one block. fsck refuses exactly this
# ("overlaps the previous Block Group"); the mount did not (audit
# 2026-11-06 M2).
#
# Staged: Block Group 0's length is stretched 16 blocks into Block Group
# 1, its checksum restamped. The mount must refuse it; the same image
# with the length restored must mount (the edit is the only difference).
#
# The stretched length no longer matches the layout its bitmap and data
# offsets were computed from, which the per-descriptor check refuses on
# its own (audit 2026-11-15 BL-33) -- before the ordering check is ever
# reached. bg_layout_any=1 turns only that exact-layout comparison off,
# so the ordering check is the sole path to the refusal.
#
# DISCRIMINATION: without the ordering check the stretched image mounts.
# NOT COVERED: the companion check that two descriptor table segments do
# not overlap each other. A chain whose segments overlap and still
# number their Block Groups consecutively needs a grown volume rebuilt by
# hand; no helper builds one yet.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"
[ -w /sys/module/cetrafs/parameters/bg_layout_any ] || { skip "bg_layout_any is missing"; ct_exit; }

IMG="$(ct_image 1200 bgovl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgovl)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
geom() { "$BG_POKE" "$IMG" "$1" --dump | sed -n "s/.* $2=\([0-9]*\).*/\1/p"; }
S0="$(geom 0 start_block)" L0="$(geom 0 length_blocks)" S1="$(geom 1 start_block)"
[ -n "$S0" ] && [ -n "$L0" ] && [ -n "$S1" ] && [ "$S1" -ge $((S0 + L0)) ] ||
    { fail "setup: two ordered Block Groups were not made (BG0 $S0+$L0, BG1 $S1)"; ct_exit; }

"$BG_POKE" "$IMG" 0 --geom=length_blocks $((S1 - S0 + 16)) >/dev/null
ct_param_set bg_layout_any 1
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    fail "a Block Group running 16 blocks into the next one mounted"
    umount "$MNT"
else
    dmesg_since "$MARK" | grep -q "starts before the previous one ends" &&
        pass "a Block Group running into the next one is refused at mount" ||
        fail "the mount was refused, but not for the overlap: $(dmesg_since "$MARK" | grep -i cetrafs | tail -2)"
fi

ct_param_set bg_layout_any 0
"$BG_POKE" "$IMG" 0 --geom=length_blocks "$L0" >/dev/null
ct_mount "$DEV" "$MNT" && pass "control: the same image with the length restored mounts" ||
    fail "control: the restored image does not mount -- the refusal above proves nothing"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
ct_exit
