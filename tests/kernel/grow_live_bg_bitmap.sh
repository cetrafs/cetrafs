#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow refuses Block Groups whose data bitmap is not zeroed on the device
#
# The commit verified each new group's header, and nothing about its
# bitmap. The allocator reads that bitmap the moment the group is handed
# out, and a region that held an earlier group's bitmap would read that
# group's allocations as its own (audit L8). The commit now reads each
# bitmap block of a new group forced-fresh and requires it to be zero
# (cetrafs_grow_check_bg_header()).
#
# Round 1: growfs writes each new header correctly but fills the new
# bitmaps with 1s (CETRAFS_GROWFS_TEST_DIRTY_BG_BITMAPS). The grow must be
# refused with nothing published: same block_group_count and layout_gen,
# block 0 unchanged, the kernel naming the bitmap. Round 2: the same grow
# without the knob completes, the earlier file reads back, fsck is clean.
#
# DISCRIMINATION: round 1 IS the control -- without the bitmap check the
# grow publishes over the dirty bitmaps (the header check passes, as it
# was written correctly).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 2400 growbmp)"
MNT="$(ct_mnt growbmp)"
ct_track mnt "$MNT"

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
sb_sum() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | md5sum; }

ct_mkfs "$DEV" -s 1200M -b 512 -z 2 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/before" bs=1M count=8 conv=fsync status=none
sum0="$(md5sum <"$MNT/before")"

bgs0="$(info block_group_count)"
gen0="$(info layout_gen)"
sb0="$(sb_sum)"
[ -n "$bgs0" ] && [ -n "$gen0" ] || { fail "setup: procfs has no block_group_count/layout_gen"; ct_exit; }

MARK="$(dmesg_mark)"
rc=0
out="$(CETRAFS_GROWFS_TEST_DIRTY_BG_BITMAPS=1 ct_growfs "$DEV" -s 1800M 2>&1)" || rc=$?
if [ "$rc" = 0 ]; then
    fail "round 1: the grow completed over Block Groups whose bitmaps were not zeroed"
else
    pass "round 1: growfs failed (rc=$rc)"
fi
[ "$(info block_group_count)" = "$bgs0" ] && [ "$(info layout_gen)" = "$gen0" ] &&
    pass "round 1: nothing published (block_group_count $bgs0, layout_gen $gen0)" ||
    fail "round 1: the layout moved to $(info block_group_count) groups, gen $(info layout_gen)"
[ "$(sb_sum)" = "$sb0" ] && pass "round 1: block 0 unchanged" || fail "round 1: block 0 was rewritten"
dmesg_since "$MARK" | grep -q "bitmap block at .* is not zeroed" &&
    pass "round 1: the kernel named the dirty bitmap" ||
    fail "round 1: no bitmap refusal in the kernel log: $(tail -2 <<<"$out" | tr '\n' ' ')"

out="$(ct_growfs "$DEV" -s 1800M 2>&1)" && pass "round 2: the grow completes once the bitmaps are zeroed" ||
    fail "round 2: the grow failed: $(tail -2 <<<"$out" | tr '\n' ' ')"
[ "$(info block_group_count)" -gt "$bgs0" ] && pass "round 2: $(info block_group_count) Block Groups published" ||
    fail "round 2: still $(info block_group_count) Block Groups"
sync
echo 3 >/proc/sys/vm/drop_caches
[ "$(md5sum <"$MNT/before")" = "$sum0" ] && pass "round 2: the earlier file reads back intact" ||
    fail "round 2: the earlier file changed"
ct_umount "$MNT"
frc=0
out="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
