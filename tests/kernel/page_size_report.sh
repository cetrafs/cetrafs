#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount reports the kernel page size it is running under
#
# This suite does not guard a behaviour. It makes a BLIND SPOT visible,
# which is the next best thing when the behaviour cannot be reached from
# here at all.
#
# The filesystem addresses in 4 KiB blocks; the page cache indexes in
# pages. Where a page is one block the two indices are the same number,
# so handing a block index to a page-index function works by accident --
# which is how one reached invalidate_inode_pages2_range() in defrag,
# leaving a page still mapped to blocks the next line freed. arm64 can
# be built with 16K or 64K pages, and there the two differ by 4x or 16x.
#
# Every machine this project runs on is 4K, so a regression test for
# that class CANNOT discriminate here: the corrected conversion and the
# raw block index compute the same number. Rather than ship a green test
# that proves nothing, the mount now states which world a result came
# from, and this asserts it is telling the truth.
#
# When a 16K or 64K host is available, that is where the defrag and
# truncate suites need to be run; this value in the output is what says
# whether they were.
#
# Until then such a kernel is REFUSED at mount (fill_super), and this
# suite also checks that refusal, through the test-only
# assume_page_size. DISCRIMINATION: without the check, the 16K and 64K
# mounts succeed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 pagesize)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pagesize)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROPS="$(ct_procdir "$DEV")/properties"
REPORTED="$(sed -n 's/^kernel_page_size: //p' "$PROPS")"
PER_PAGE="$(sed -n 's/^blocks_per_page: //p' "$PROPS")"
HOST="$(getconf PAGESIZE)"

[ -n "$REPORTED" ] || fail "the mount does not report kernel_page_size at all"

[ "$REPORTED" = "$HOST" ] &&
    pass "the mount reports the page size it actually runs under ($REPORTED)" ||
    fail "reported page size $REPORTED but the host says $HOST"

BS="$(sed -n 's/^block_size: //p' "$PROPS")"
[ "$PER_PAGE" = "$((REPORTED / BS))" ] &&
    pass "blocks_per_page is consistent with it ($PER_PAGE block(s) of $BS bytes per page)" ||
    fail "blocks_per_page says $PER_PAGE, which is not $REPORTED/$BS"

# The assumption the module asserts at build time, restated where a
# human reads it: a page must hold a whole number of blocks.
[ "$((REPORTED % BS))" = 0 ] &&
    pass "the page size is a whole number of filesystem blocks" ||
    fail "page size $REPORTED is not a multiple of the $BS-byte block -- the module's static_assert should have refused this build"

# Larger pages are refused at mount rather than run untested. Reached
# here through the test-only assume_page_size, since every host is 4K.
# The check itself is exercised; whether a REAL 16K kernel takes the
# same branch is PAGE_SIZE, a compile-time constant -- not reachable.
ct_umount "$MNT"
if [ -w /sys/module/cetrafs/parameters/assume_page_size ]; then
    for ps in 16384 65536; do
        ct_param_set assume_page_size "$ps"
        MARK="$(dmesg_mark)"
        if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
            fail "a ${ps}-byte page size was mounted"
            umount "$MNT"
        elif dmesg_since "$MARK" | grep -q "page size is $ps bytes"; then
            pass "a ${ps}-byte page size is refused at mount, and says why"
        else
            fail "the ${ps}-byte mount failed, but not with the page-size refusal"
        fi
    done
    ct_param_set assume_page_size 0
    ct_mount "$DEV" "$MNT"
    pass "the real page size still mounts"
else
    fail "assume_page_size is missing: the refusal is not reachable from here"
    ct_mount "$DEV" "$MNT"
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
