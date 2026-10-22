#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed reader-set publish REFUSES the open -- and leaves state balanced
#
# A read-open takes no cross-node lock -- one writer and lock-free readers
# is the whole clustering model -- so the only thing stopping a peer
# unlinking a file this node is reading is the read-presence bitmask in
# the inode record. This node sets its bit on its FIRST local read-open
# and clears it on its LAST, one CAW per edge rather than per open.
#
# A failed publish used to be tolerated: the open succeeded unpublished,
# with the retry left to "the next open". But the publish only runs on the
# counter's 0->1 edge, so for a long-lived fd (a running VM image) one
# transient failure meant running invisible to every peer's unlink guard
# for the fd's ENTIRE life -- an unbounded window, not a transient one.
# The open is now refused outright, same as a nofilelock write-open's
# publish failure always was: nothing on disk to undo, and the caller just
# retries the open.
#
# lock_fail_reader_publish is a test-only module param, because the real
# failure modes (CAS retry exhaustion, a device error) cannot be provoked
# from a test.
#
# Measured discrimination: with the tolerate-the-failure behaviour
# restored, "the forced-failure open is REFUSED" fails (the open
# succeeds). The balance assertions after it guard the unwind: a failing
# path that forgot to undo its counter bumps would leave the 0->1 edge
# unreachable, and "the next read-open publishes" would come back
# readers=0x0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

FAIL_PARAM=/sys/module/cetrafs/parameters/lock_fail_reader_publish
restore_publish() {
    [ -w "$FAIL_PARAM" ] && echo 0 >"$FAIL_PARAM"
    return 0
}

DEV="$(ct_dev 560 rpr)"
MNT="$(ct_mnt rpr)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

echo content >"$MNT/r"
RINO="$(stat -c '%i' "$MNT/r")"

readers_field() { "$LOCK_POKE" "$DEV" "$RINO" | grep -oP 'readers=\K0x[0-9a-f]+'; }

log "checking a read-open publishes this node normally"
exec 9<"$MNT/r"
[ "$(readers_field)" = "0x1" ] && pass "read presence: a read-open publishes bit 0" ||
    fail "read presence: readers=$(readers_field) with a reader open, expected 0x1"
exec 9<&-
[ "$(readers_field)" = "0x0" ] && pass "read presence: the last close withdraws it" ||
    fail "read presence: readers=$(readers_field) after the last close, expected 0x0"

log "checking a FAILED publish refuses the open"
echo 1 >"$FAIL_PARAM"
if cat "$MNT/r" >/dev/null 2>&1; then
    restore_publish
    fail "read presence: the open SUCCEEDED with its publish forced to fail -- an invisible reader was admitted"
else
    pass "read presence: the forced-failure open is REFUSED (no invisible reader)"
fi
[ "$(readers_field)" = "0x0" ] && pass "read presence: nothing was left published by the refused open" ||
    fail "read presence: readers=$(readers_field) after the refused open, expected 0x0"
restore_publish

# The unwind guard: the refused open must have undone its counter bumps,
# or this next open's 0->1 edge never fires and nothing publishes.
log "checking the refusal left the counters balanced"
exec 9<"$MNT/r"
AFTER="$(readers_field)"
[ "$AFTER" = "0x1" ] && pass "read presence: the next read-open publishes normally (the refusal unwound its counts)" ||
    fail "read presence: readers=$AFTER on the open after a refusal -- the failing path left a counter unbalanced"
# And writing through a fresh fd proves the local open count unwound too
# (a leaked lock_local_open_count would misreport the file as open).
exec 9<&-
[ "$(readers_field)" = "0x0" ] && pass "read presence: and the following close still withdraws" ||
    fail "read presence: readers=$(readers_field) after close -- the counter is unbalanced"

# One more full cycle: balance must hold repeatedly, not just once.
echo 1 >"$FAIL_PARAM"
cat "$MNT/r" >/dev/null 2>&1 && { restore_publish; fail "second forced failure: the open succeeded"; }
restore_publish
exec 9<"$MNT/r"
[ "$(readers_field)" = "0x1" ] && pass "read presence: refusal/retry cycle is repeatable" ||
    fail "read presence: readers=$(readers_field) after a second refusal cycle"
exec 9<&-

ct_umount "$MNT"
ct_exit
