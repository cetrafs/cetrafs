#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow refuses an inode table segment whose bitmap is not empty on the device
#
# A new Block Group's header and bitmap are read back before a grow
# publishes (grow_live_bg_header.sh, grow_live_bg_bitmap.sh); a new
# inode table segment only had its header read. growfs zeroes and syncs
# its bitmap first, so a dirty one means the region was never written
# -- and the allocator reads it the moment the grow publishes: set bits
# are numbers nobody can create, or records nobody created (audit
# 2026-11-15 F-64). The commit now reads the new segment's bitmap
# forced-fresh and requires it empty (cetrafs_grow_check_iseg_bitmap()).
#
# Round 1: growfs adds inodes but leaves the new segment's bitmap full of
# 1s (CETRAFS_GROWFS_TEST_DIRTY_INODE_BITMAP): refused, nothing
# published, the kernel names the bitmap. Round 2: the same grow without
# the knob completes, a file is created in the new numbers, fsck is
# clean.
#
# DISCRIMINATION: grow_hdr_check_off=1 on a second volume: the dirty
# grow publishes (inodes_count moves).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_param_set grow_hdr_check_off 0

# grow_once <dev> <mnt> <dirty 0|1> -> "<rc> <inodes after> <named yes|no>"
grow_once() {
    local mark rc=0 out
    mark="$(dmesg_mark)"
    if [ "$3" = 1 ]; then
        out="$(CETRAFS_GROWFS_TEST_DIRTY_INODE_BITMAP=1 ct_growfs "$1" -s 1100M -N 1300 2>&1)" || rc=$?
    else
        out="$(ct_growfs "$1" -s 1100M -N 1300 2>&1)" || rc=$?
    fi
    echo "$rc $(sed -n 's/^inodes_count: //p' "$(ct_procdir "$1")/info")" \
        "$(dmesg_since "$mark" | grep -q "new inode table segment's bitmap block at .* is not an empty bitmap" && echo yes || echo no)"
}

DEV="$(ct_big_dev 1100 gisb)"
MNT="$(ct_mnt gisb)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(sed -n 's/^inodes_count: //p' "$(ct_procdir "$DEV")/info")" = 1024 ] || { fail "setup: not 1024 inodes"; ct_exit; }
gen0="$(sed -n 's/^layout_gen: //p' "$(ct_procdir "$DEV")/info")"

read -r RC N NAMED <<<"$(grow_once "$DEV" "$MNT" 1)"
[ "$RC" != 0 ] && [ "$N" = 1024 ] && [ "$(sed -n 's/^layout_gen: //p' "$(ct_procdir "$DEV")/info")" = "$gen0" ] &&
    pass "round 1: the grow over a dirty inode bitmap is refused, nothing published" ||
    fail "round 1: rc=$RC, $N inodes, layout_gen $(sed -n 's/^layout_gen: //p' "$(ct_procdir "$DEV")/info") (was $gen0)"
[ "$NAMED" = yes ] && pass "round 1: the kernel named the bitmap" || fail "round 1: no bitmap refusal in the kernel log"

read -r RC N NAMED <<<"$(grow_once "$DEV" "$MNT" 0)"
[ "$RC" = 0 ] && [ "$N" = 1300 ] && pass "round 2: the clean grow adds the inodes ($N)" || fail "round 2: rc=$RC, $N inodes"
python3 -I - "$MNT" <<'PY' || fail "round 2: creating past the old 1024 inodes failed"
import os, sys
for i in range(1100):
    open(os.path.join(sys.argv[1], "f%d" % i), "w").close()
PY
[ "$(stat -c %i "$MNT/f1099")" -gt 1024 ] && pass "round 2: a file got a number from the new segment" ||
    fail "round 2: the last file is ino $(stat -c %i "$MNT/f1099")"
ct_umount "$MNT"
frc=0
out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "round 2: fsck clean" || fail "round 2: fsck rc=$frc: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"

DEV2="$(ct_big_dev 1100 gisb2)"
MNT2="$(ct_mnt gisb2)"
ct_track mnt "$MNT2"
ct_mkfs "$DEV2" -s 600M -b 512 -z 1 -J 0 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV2" "$MNT2"
ct_param_set grow_hdr_check_off 1
read -r RC N NAMED <<<"$(grow_once "$DEV2" "$MNT2" 1)"
ct_param_set grow_hdr_check_off 0
[ "$N" = 1300 ] && pass "control: without the check the dirty grow publishes -- the suite discriminates" ||
    fail "control: rc=$RC, $N inodes -- something else refused it; the suite cannot tell"
umount "$MNT2" 2>/dev/null || umount -l "$MNT2"
ct_exit
