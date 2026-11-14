#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the ENOSPC recount corrects the Zone Group aggregate along with the Block Group
#
# When an allocation finds a Block Group full that its count called
# free, the group is recounted from its bitmap. Its Zone Group's
# aggregate summed the same wrong count and was left alone, so fsck's
# aggregate check failed until the next ownership transfer (audit
# 2026-11-14 A6).
#
# alloc_inflate_once gives the next allocation's group 1000 blocks of
# free count it does not have -- the aggregate too, as any accrual -- and
# then fails it ENOSPC, so the allocator recounts. After a clean
# unmount, fsck must find the aggregate equal to its groups.
#
# DISCRIMINATION: recount_agg_off leaves the aggregate alone, as before;
# fsck then reports it 1000 blocks high.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in alloc_inflate_once recount_agg_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt eagg)"
ct_track mnt "$MNT"
ct_param_set alloc_inflate_once 0
ct_param_set recount_agg_off 0
P=/sys/module/cetrafs/parameters

# <agg_off 0|1> -> "<recounted yes|no> <aggregate ERR lines>"
probe() {
    local dev mark out rec
    dev="$(ct_loop "$(ct_image 560 "eagg$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/a" bs=64K count=16 status=none
    sync
    echo "$1" >$P/recount_agg_off
    mark="$(dmesg_mark)"
    echo 1000 >$P/alloc_inflate_once
    dd if=/dev/urandom of="$MNT/b" bs=64K count=1 status=none
    sync
    echo 0 >$P/alloc_inflate_once
    echo 0 >$P/recount_agg_off
    dmesg_since "$mark" | grep -q "recounted" && rec=yes || rec=no
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    echo "$rec $(grep -c "ERR: ZG.*aggregate" <<<"$out" || true)"
}

read -r R N <<<"$(probe 0)"
[ "$R" = yes ] || fail "setup: no recount happened -- the injected ENOSPC was not reached"
[ "$N" = 0 ] && pass "after the recount the Zone Group aggregate matches its groups (fsck)" ||
    fail "fsck reports the aggregate off after the recount ($N line(s))"
read -r R0 N0 <<<"$(probe 1)"
[ "$R0" = yes ] && [ "$N0" -gt 0 ] && pass "control: without the correction fsck reports the aggregate -- the suite discriminates" ||
    fail "control: recounted=$R0, $N0 aggregate line(s) -- the suite cannot tell"
ct_exit
