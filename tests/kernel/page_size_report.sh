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

if [ "$PER_PAGE" = 1 ]; then
    log "NOTE: one block per page. Block indices and page indices coincide here,"
    log "      so a block/page mix-up is INVISIBLE to this entire gate."
else
    log "NOTE: $PER_PAGE blocks per page -- this run does exercise the distinction."
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
