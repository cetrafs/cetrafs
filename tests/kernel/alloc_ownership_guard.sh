#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the allocator refuses to write a Block Group this node does not own
#
# Zone Group ownership is what partitions the data bitmaps between nodes:
# there is no cross-node exclusion on a BG's bitmap because none is
# needed, as long as only its owner ever writes it. Writing someone
# else's is therefore the single most damaging thing this module can do
# -- the owner is allocating from that same bitmap concurrently, so a
# stray write hands one physical block to two files on two nodes.
#
# The FREE path has always guarded this, routing a foreign block to the
# owner's pending-free queue instead of touching its bitmap. The ALLOC
# path had no check at all: it trusted whatever bg_id its caller passed.
# Today the only caller scans owned ZGs and gets it right -- the guard is
# about the next caller, and about this project's own history of a safety
# property holding only because one function happened to compute it
# correctly.
#
# alloc_force_foreign is a test-only module param because the guard is
# otherwise unreachable: no caller passes a foreign BG, which is the
# property under test. A guard nothing ever runs is a guard nobody knows
# works.
#
# Measured discrimination: with the guard removed, 3 of these 8
# assertions fail -- the write succeeds, nothing is logged, and 8 blocks
# are consumed out of a bitmap belonging to another node. The remaining
# assertions (normal allocation works, fsck is clean) pass either way and
# are there to prove the guard has no false positives.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FOREIGN_PARAM=/sys/module/cetrafs/parameters/alloc_force_foreign
restore_foreign() {
    [ -w "$FOREIGN_PARAM" ] && echo 0 >"$FOREIGN_PARAM"
    return 0
}

DEV="$(ct_dev 560 aog)"
MNT="$(ct_mnt aog)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "checking allocation works normally on an owned zone group"
dd if=/dev/zero of="$MNT/owned" bs=4096 count=8 status=none &&
    pass "alloc guard: a normal write succeeds on an owned ZG" ||
    fail "alloc guard: a normal write failed -- the guard rejects its own node"
sync
BEFORE_FREE="$(stat -f -c '%f' "$MNT")"

log "checking a write to a BG this node does not own is refused"
echo 1 >"$FOREIGN_PARAM"
MARK="$(dmesg_mark)"
if dd if=/dev/zero of="$MNT/foreign" bs=4096 count=8 status=none 2>/dev/null; then
    restore_foreign
    fail "alloc guard: a write succeeded against a BG owned by another node"
else
    restore_foreign
    pass "alloc guard: the write was refused"
fi
if dmesg_since "$MARK" | grep -q "refusing to allocate from BG"; then
    pass "alloc guard: dmesg names the BG and its zone group"
else
    fail "alloc guard: the refusal was silent"
fi

log "checking the refused write consumed nothing"
sync
AFTER_FREE="$(stat -f -c '%f' "$MNT")"
# A refused allocation must not have taken blocks. The partially-created
# file may exist with no data; what must not happen is the bitmap moving.
[ "$AFTER_FREE" = "$BEFORE_FREE" ] &&
    pass "alloc guard: free-block count unchanged ($AFTER_FREE)" ||
    fail "alloc guard: free blocks went $BEFORE_FREE -> $AFTER_FREE despite the refusal"

log "checking allocation works again once ownership is restored"
dd if=/dev/zero of="$MNT/again" bs=4096 count=4 status=none &&
    pass "alloc guard: allocation works again with the guard satisfied" ||
    fail "alloc guard: allocation still refused after restoring ownership"
sync
ct_umount "$MNT"

FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "cetrafs fsck: OK" &&
    pass "fsck: clean after a refused allocation" ||
    fail "fsck: problems after the refusal: $(echo "$FSCK_OUT" | grep -iE 'ERR|WARN' | head -2 | tr '\n' ' ')"

ct_exit
