#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a fence judged before its node came back does not land after
#
# A reclaim judges a peer stale, then fences it (bumps its row's
# fence_epoch) and takes what it held. The fence checked only that the
# row was REGISTERED. A node that remounted in between re-attached to
# the SAME row -- same id, new incarnation, beating -- so the fence
# revoked a LIVE node's lease and the reclaim went on to take what the
# new incarnation holds. The ZG steal had the same shape and compares
# the judged hb_seq (zg_steal_vs_reattach.sh); now the fence does too.
#
# Staged: a file locked by node 1, whose row is planted and left to go
# stale. A write-open judges it stale; fence_stall_ms holds it between
# the verdict and the fence while node 1 "re-attaches" (its row beats).
# The open must be refused as for a live holder, and node 1's lease and
# lock must be untouched.
#
# DISCRIMINATION: with the fence checking only REGISTERED, the open
# succeeds, node 1's fence_epoch moves and the lock is this node's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_stall_ms ] || { skip "fence_stall_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 fencereatt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fencereatt)"
ct_mkfs_small "$DEV" >/dev/null
set_stale_window "$TEST_STALE_SECS"
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
INO="$(stat -c %i "$MNT/f")"
sync
blockdev --flushbufs "$DEV"

# Node 1: registered, then silent; it holds f's lock.
"$NPOKE" "$IMG" 1 1 bb "$(date +%s)" >/dev/null
"$LPOKE" "$IMG" "$INO" 1 1 >/dev/null
epoch() { sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' <<<"$("$NPOKE" "$IMG" 1)"; }
E0="$(epoch)"

# First look: the watch samples node 1's row (alive, by definition).
{ : >>"$MNT/f"; } 2>/dev/null && { fail "setup: f opened for write past node 1's lock"; ct_exit; }
wait_out_stale_window

ct_param_set fence_stall_ms 4000
MARK="$(dmesg_mark)"
( rc=0; { : >>"$MNT/f"; } 2>"$IMG.err" || rc=$?; echo "$rc" >"$IMG.rc" ) &
OPID=$!; ct_track file "$IMG.rc"; ct_track file "$IMG.err"
for _ in $(seq 1 60); do [ "$(cat /sys/module/cetrafs/parameters/fence_stall_ms)" = 0 ] && break; sleep 0.1; done
[ "$(cat /sys/module/cetrafs/parameters/fence_stall_ms)" = 0 ] ||
    { fail "setup: the open never judged node 1 stale"; ct_param_set fence_stall_ms 0; wait "$OPID"; ct_exit; }
# Node 1 remounts: same row, beating again -- and it KEEPS beating, as
# a mounted node does; a single beat goes stale again inside the stall.
( while [ ! -e "$IMG.rc" ]; do "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1 || true; sleep 0.5; done ) &
BEATER=$!
wait "$OPID" || true
kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true
pass "setup: the open judged node 1 stale and was held before its fence; node 1 beat meanwhile"

[ "$(cat "$IMG.rc")" != 0 ] && grep -q "Text file busy" "$IMG.err" &&
    pass "the open was refused as for a live holder (ETXTBSY)" ||
    fail "the open went ahead (rc=$(cat "$IMG.rc"): $(cat "$IMG.err")) on a node that came back"
dmesg_since "$MARK" | grep -q "node 1 came back since it was judged stale" &&
    pass "and said why" || fail "no 'came back' line: $(dmesg_since "$MARK" | grep -m1 fence)"
[ "$(epoch)" = "$E0" ] && pass "node 1's lease was not revoked (fence_epoch $E0)" ||
    fail "node 1's lease was revoked after it came back: fence_epoch $E0 -> $(epoch)"
grep -q "owner=1 mode=1" <<<"$("$LPOKE" "$IMG" "$INO")" && pass "and its lock is still its own" ||
    fail "the lock was taken from a live node: $("$LPOKE" "$IMG" "$INO")"
ct_umount "$MNT"
ct_exit
