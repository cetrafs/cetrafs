#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a link count at the top of its range never wraps to 0
#
# nlink is a u32 in the record and the namespace CAS stored (u32) of the
# new count: 2^32 links read back as 0 -- a dead inode, freed with names
# still pointing at it. s_max_links was unset, so nothing refused the
# link that got there (audit 2026-11-05, section 3).
#
# A. After a remount the in-core count is 0xFFFFFFFF: link() is EMLINK.
# B. A peer's links land between a link's checks (made on a count of 1)
#    and its CAS (link_step_stall_ms): the apply must saturate, not wrap.
#
# DISCRIMINATION: proven 2026-11-05, each half alone: without
# s_max_links, A's link() succeeds; with the plain (u32) store, B's
# record wraps to nlink 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 nlsat)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nlsat)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo a >"$MNT/a"
echo b >"$MNT/b"
sync
IA="$(stat -c %i "$MNT/a")"
IB="$(stat -c %i "$MNT/b")"
ct_umount "$MNT"
recnlink() { "$LOCK_POKE" "$IMG" "$1" --rec | sed -n 's/.*nlink=\([0-9]*\).*/\1/p'; }

# ---------------------------------------------------------------- A
"$IPOKE" "$IMG" nlink "$IA" 4294967295 2>/dev/null
[ "$(recnlink "$IA")" = 4294967295 ] || { fail "setup: the poke did not set nlink ($(recnlink "$IA"))"; ct_exit; }
ct_mount "$DEV" "$MNT"
ERR="$(ln "$MNT/a" "$MNT/a2" 2>&1)" && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -qi "too many links" <<<"$ERR" && pass "A: link() at the top of the range is EMLINK" ||
    fail "A: link() at nlink 0xFFFFFFFF returned rc=$RC: $ERR"
ct_umount "$MNT"
N="$(recnlink "$IA")"
[ "$N" != 0 ] && pass "A: the record's count did not wrap (nlink $N)" || fail "A: the record's nlink wrapped to 0"

# ---------------------------------------------------------------- B
ct_mount "$DEV" "$MNT"
stat "$MNT/b" >/dev/null # in-core nlink 1
ct_param_set link_step_stall_ms 1500
ln "$MNT/b" "$MNT/b2" 2>/dev/null &
LP=$!
sleep 0.5
"$IPOKE" "$IMG" nlink "$IB" 4294967295 2>/dev/null # a peer's links land under the link
wait "$LP" && pass "B: the link passed every check on a count of 1 (setup)" ||
    { fail "setup: B's link was refused -- the apply was never reached"; ct_param_set link_step_stall_ms 0; ct_umount "$MNT"; ct_exit; }
ct_param_set link_step_stall_ms 0
ct_umount "$MNT"
N="$(recnlink "$IB")"
[ "$N" != 0 ] && pass "B: a link applied over a peer's maximal count saturates (nlink $N)" ||
    fail "B: a link applied over a peer's 0xFFFFFFFF wrapped the record's nlink to 0"
ct_exit
