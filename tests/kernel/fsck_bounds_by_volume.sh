#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck bounds the layout by the volume's total_blocks, as the mount does, not by the device
#
# fsck checked every region against the size of the DEVICE, the kernel
# against the superblock's total_blocks. A device larger than its volume
# is normal -- grown and not yet grown into -- so a layout running past
# total_blocks but inside the device was called clean by fsck and
# refused by the mount (audit 2026-11-06 L25).
#
# Staged: total_blocks lowered on the image to one block short of the
# end of the data area, superblock re-checksummed. The mount must refuse
# it (the setup), and fsck must report it.
#
# DISCRIMINATION: bounded by the device, fsck passes the volume.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBP="$(ct_helper sb_poke)"

IMG="$(ct_image 560 fsckvb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckvb)"
ct_mkfs_small "$DEV" >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: a fresh volume is not clean"; ct_exit; }
field() { "$SBP" "$IMG" 2>/dev/null | sed -n "s/^$1=//p" | head -1; }
TB="$(field total_blocks)"
DE=$(( $(field bg_regions_start) + $(field bg_size_blocks) )) # one BG, never grown
[ -n "$TB" ] && [ "$DE" -le "$TB" ] || { fail "setup: cannot read the layout ($TB, $DE)"; ct_exit; }
NEW=$((DE - 1))
"$SBP" "$IMG" total_blocks "$NEW" >/dev/null 2>&1
blockdev --flushbufs "$DEV"
log "total_blocks $TB -> $NEW, one block short of the data area's end $DE, on a device of $TB blocks"

ct_track mnt "$MNT"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "setup: the mount accepted a volume whose layout runs past total_blocks"
    ct_exit
fi
pass "setup: the mount refuses the volume"
OUT="$(ct_fsck "$DEV" 2>&1)" && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q "total_blocks" <<<"$OUT" &&
    pass "fsck reports it: $(grep -m1 total_blocks <<<"$OUT")" ||
    fail "fsck called a volume the mount refuses clean (exit $RC): $(grep -m2 -E '^(ERR|WARN)' <<<"$OUT")"
ct_exit
