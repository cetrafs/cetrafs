#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node the no-CAW gate declared dead comes back as after a crash and sweeps its old claims
#
# On a device without compare-and-write, a mount watches every
# registered row for the stale window and fences the ones that never
# beat, recording the verdict in the row so the next mount need not
# watch again. That verdict used to be written as last_seen = 0 -- the
# same sentinel a node writes when it unmounts cleanly. When the dead
# node came back it re-attached as if it had left cleanly, skipped its
# own-claim sweeps, and every claim of its crashed incarnation read live
# (L3). The row now records WHY it is not beating (departure, format
# 0x000A): CLEAN from the node's own unmount, DEAD from a peer's verdict.
#
#  A. the gate's verdict on a silent row is DEAD, never CLEAN.
#  B. a node coming back to a DEAD row re-attaches as after a crash: the
#     lock, presence bit and namespace lock of its old incarnation are
#     cleared.
#  C. control: a CLEAN row re-attaches without a sweep (nothing to clear,
#     and the mount says it re-attached cleanly).
#
# DISCRIMINATION: with the gate writing CLEAN, A fails; with a DEAD row
# treated as a clean re-attach, B's three claims survive the remount
# (checked 2026-11-10).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 deadverdict)"
MNT="$(ct_mnt deadverdict)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2

dep() { blockdev --flushbufs "$DEV"; "$NODE_POKE" "$DEV" "$1" | sed -n 's/.* departure=\([0-9]*\) .*/\1/p'; }

# ------------------------------------------------------------------- A
log "A: the no-CAW gate's verdict on a silent row"
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
[ "$(dep 1)" = 0 ] || { fail "setup: the planted peer row already records a departure ($(dep 1))"; ct_exit; }
set_stale_window "$TEST_STALE_SECS"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -qE "waiting ([0-9]+)s to see whether 1 other node" ||
    { fail "setup: the mount never watched the silent row"; ct_exit; }
[ "$(dep 1)" = 2 ] && pass "A: the gate recorded row 1 as DEAD" ||
    fail "A: the gate recorded departure=$(dep 1) for a node it watched die (2 = DEAD expected)"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/dir"
for f in locked read; do echo "$f" >"$MNT/$f"; done
LI="$(stat -c %i "$MNT/locked")"; RI="$(stat -c %i "$MNT/read")"; DI="$(stat -c %i "$MNT/dir")"
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null # the peer is gone for good: FREE

# ------------------------------------------------------------------- B
log "B: this node comes back to a row a peer declared DEAD"
# What the crashed incarnation left: claims stamped with its row, and the
# verdict a no-CAW peer recorded after watching it.
"$LOCK_POKE" "$DEV" "$LI" "$NID" 1 >/dev/null
"$LOCK_POKE" "$DEV" "$RI" --reader "$NID" >/dev/null
"$LOCK_POKE" "$DEV" "$DI" --ns "$NID" >/dev/null
"$NODE_POKE" "$DEV" "$NID" --depart 2 >/dev/null
[ "$(dep "$NID")" = 2 ] &&
    grep -q "owner=$NID mode=1" <<<"$("$LOCK_POKE" "$DEV" "$LI")" &&
    grep -q "ns_owner=$NID" <<<"$("$LOCK_POKE" "$DEV" "$DI")" &&
    ! grep -q 'readers=0x0$' <<<"$("$LOCK_POKE" "$DEV" "$RI")" ||
    { fail "setup: the claims and the DEAD verdict are not on the device"; ct_exit; }
pass "B: setup: a lock, a presence bit and a namespace lock of row $NID, and the row recorded DEAD"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
[ "$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")" = "$NID" ] &&
    dmesg_since "$MARK" | grep -q "re-attached row $NID" ||
    { fail "setup: the remount did not re-attach row $NID"; ct_umount "$MNT"; ct_exit; }
dmesg_since "$MARK" | grep -q "re-attached after an unclean departure" &&
    pass "B: the mount treated it as a crash" || fail "B: the mount re-attached a DEAD row as a clean departure"
L="$("$LOCK_POKE" "$DEV" "$LI")"; R="$("$LOCK_POKE" "$DEV" "$RI")"; D="$("$LOCK_POKE" "$DEV" "$DI")"
grep -q 'mode=0' <<<"$L" && pass "B: the old exclusive lock is gone" || fail "B: the old exclusive lock is still held: $L"
grep -q 'readers=0x0$' <<<"$R" && pass "B: the old presence bit is gone" || fail "B: the old presence bit is still set: $R"
grep -q 'ns_owner=65535' <<<"$D" && pass "B: the old namespace lock is gone" || fail "B: the old namespace lock is still held: $D"
[ "$(dep "$NID")" = 0 ] && pass "B: and the row is mounted again (departure none)" ||
    fail "B: the re-attached row still records departure=$(dep "$NID")"
ct_umount "$MNT"

# ------------------------------------------------------------------- C
log "C: control -- a clean departure re-attaches without a sweep"
[ "$(dep "$NID")" = 1 ] && pass "C: the unmount recorded CLEAN" ||
    fail "C: the unmount recorded departure=$(dep "$NID"), not CLEAN"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$MARK" | grep -q "re-attached row $NID" || fail "C: the remount did not re-attach row $NID"
dmesg_since "$MARK" | grep -qiE "unclean|sweep" &&
    fail "C: a clean re-attach was treated as a crash: $(dmesg_since "$MARK" | grep -m1 -iE 'unclean|sweep')" ||
    pass "C: no own-claim sweep after a clean departure"
ct_umount "$MNT"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
