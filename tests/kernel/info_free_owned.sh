#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# info says how much of the free space THIS node can allocate
#
# A node allocates only from Block Groups it owns or nobody owns, and
# never takes space back from a live peer, so it can return ENOSPC while
# df shows room -- and nothing said how much was really this node's
# (audit 2026-11-14 O4). info now carries free_data_blocks_owned and
# free_data_blocks_unowned_bgs.
#
#   1. both lines are there, and never exceed free_data_blocks;
#   2. a 4 MiB write takes its 1024 blocks out of free_data_blocks_owned.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IMG="$(ct_image 560 ifo)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ifo)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
PD="$(ct_procdir "$DEV")"
val() { sed -n "s/^$1: //p" "$PD/info"; }
O0="$(val free_data_blocks_owned)"
U0="$(val free_data_blocks_unowned_bgs)"
F0="$(val free_data_blocks)"
log "free $F0, owned $O0, unowned groups $U0"
if [ -n "$O0" ] && [ -n "$U0" ] && [ $((O0 + U0)) -le "$F0" ] && [ "$O0" -gt 0 ]; then
    pass "1: info splits out what this node can allocate ($O0 owned + $U0 unowned of $F0)"
else
    fail "1: free_data_blocks_owned/_unowned_bgs missing or inconsistent: '$O0' '$U0' of '$F0'"
fi
dd if=/dev/zero of="$MNT/f" bs=1M count=4 status=none
sync
O1="$(val free_data_blocks_owned)"
log "after a 4 MiB write: owned $O1"
[ -n "$O1" ] && [ $((O0 - O1)) -ge 1024 ] && [ $((O0 - O1)) -le 1100 ] &&
    pass "2: the write came out of this node's own space ($((O0 - O1)) blocks)" ||
    fail "2: owned went $O0 -> $O1 for a 1024-block write"
ct_umount "$MNT"
ct_exit
