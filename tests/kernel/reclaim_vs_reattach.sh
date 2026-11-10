#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reclaim that races its holder's re-attach leaves a re-taken claim alone
#
# Reclaiming a dead node's claim is: judge its row stale, fence it
# (bound to the incarnation judged), replay its journal, then CAS the
# claim away. That last CAS compares only the holder's row NUMBER. A
# holder that re-attached in between, swept its leftovers and took the
# same claim again wrote exactly the bytes the CAS compares -- so the
# CAS took a LIVE node's file lock, its reader bit, or its namespace
# lock, and neither side could tell (audit R8).
#
# The file lock, presence bits and namespace lock now carry the
# incarnation that took them (format 0x000A), and the swap compares it:
# a claim the holder took again after re-attaching carries its new
# incarnation and cannot be displaced (reclaim_incarnation covers the
# other half, a re-attach that did not re-take).
#
# The holder is registry row 1, a departed node (stale at once); its
# re-attach is a beat and a new incarnation poked onto its row while the
# reclaim is held between fence and CAS (reclaim_stall_after_fence_ms),
# and its re-claim is stamped with that incarnation, as a real open's is.
#
# DISCRIMINATION: reattach_after_fence_force=0 (never detect) with a
# re-attach that did NOT re-take the lock -- the open goes through, so
# the staging reaches the swap (run as the last section); without the
# incarnation compare the lock and reader sections lose their claim.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_after_fence_ms ] || { skip "reclaim_stall_after_fence_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 rvr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rvr)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
for f in lockf readf; do dd if=/dev/zero of="$MNT/$f" bs=4096 count=4 conv=fsync status=none; done
I_LOCK="$(stat -c %i "$MNT/lockf")"
I_READ="$(stat -c %i "$MNT/readf")"
I_DIR="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"

# Row 1: a node that departed cleanly -- stale at once, no watch -- at
# incarnation 100, holding claims stamped with it.
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1 || fail "setup: could not register row 1"
"$NPOKE" "$IMG" 1 --inc 100 >/dev/null
INODE_LOCK_POKE_INC=100 "$LPOKE" "$IMG" "$I_LOCK" 1 1 >/dev/null
INODE_LOCK_POKE_INC=100 "$LPOKE" "$IMG" "$I_READ" --reader 1 >/dev/null
INODE_LOCK_POKE_INC=100 "$LPOKE" "$IMG" "$I_DIR" --ns 1 >/dev/null
ct_mount "$DEV" "$MNT"

# reattach_during <retake> <cmd...>: run <cmd> with the reclaim held
# after its fence while row 1 re-attaches (a beat, incarnation 200) and
# runs <retake> -- its re-claim, stamped with 200 -- or "true" for none;
# prints "<rc>".
reattach_during() {
    local rc=0 retake="$1"
    shift
    ct_param_set reclaim_stall_after_fence_ms 2000
    ( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$NPOKE" "$IMG" 1 --inc 200 >/dev/null 2>&1
      eval "INODE_LOCK_POKE_INC=200 $retake" >/dev/null 2>&1 ) &
    local B=$!
    "$@" 2>/dev/null || rc=$?
    wait "$B" || true
    ct_param_set reclaim_stall_after_fence_ms 0
    echo "$rc"
}
lockf() { "$LPOKE" "$IMG" "$1"; }

# 1. The file lock: a write-open steals it.
RC="$(reattach_during '"$LPOKE" "$IMG" "$I_LOCK" 1 1' python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/lockf")"
L="$(lockf "$I_LOCK")"
log "lock: open rc=$RC; $L"
[ "$RC" != 0 ] && pass "lock: the write-open was refused -- the holder came back" ||
    fail "lock: the write-open succeeded over a holder that re-attached during the reclaim"
grep -q "owner=1 mode=1" <<<"$L" && pass "lock: the lock is the holder's again ($L)" ||
    fail "lock: the holder's lock was taken: $L"

# Row 1 departs again, so the next reclaim is legitimate to start.
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1
"$NPOKE" "$IMG" 1 --inc 100 >/dev/null

# 2. A reader bit: a write-open clears a stale reader first.
RC="$(reattach_during '"$LPOKE" "$IMG" "$I_READ" --reader 1' python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/readf")"
L="$(lockf "$I_READ")"
log "reader: open rc=$RC; $L"
[ "$RC" != 0 ] && pass "reader: the write-open was refused -- a live reader came back" ||
    fail "reader: the write-open succeeded past a reader that re-attached during the reclaim"
grep -q "readers=0x2" <<<"$L" && pass "reader: its bit is set again ($L)" ||
    fail "reader: the re-attached reader's bit was cleared: $L"

"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1

# 3. A directory's namespace lock: a create breaks it. Bounded: the
# acquire keeps trying while the holder looks live.
ct_param_set reclaim_stall_after_fence_ms 2000
( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$NPOKE" "$IMG" 1 --inc 200 >/dev/null 2>&1
  INODE_LOCK_POKE_INC=200 "$LPOKE" "$IMG" "$I_DIR" --ns 1 >/dev/null 2>&1
  for _ in $(seq 1 30); do sleep 1; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; done ) &
B=$!
RC=0
timeout 25 touch "$MNT/d/new" 2>/dev/null || RC=$?
kill "$B" 2>/dev/null || true; wait "$B" 2>/dev/null || true
ct_param_set reclaim_stall_after_fence_ms 0
L="$(lockf "$I_DIR")"
log "nslock: create rc=$RC; $L"
grep -q "ns_owner=1 " <<<"$L" && grep -q " ns_inc=200 " <<<"$("$LPOKE" "$IMG" "$I_DIR" --incs)" &&
    pass "nslock: the namespace lock is still the holder's, incarnation 200 ($L)" ||
    fail "nslock: the re-attached holder's namespace lock was taken: $L"
[ "$RC" != 0 ] && pass "nslock: the create did not go through under a live holder" ||
    fail "nslock: the create completed under a namespace lock a live node holds"

INODE_LOCK_POKE_INC=0 "$LPOKE" "$IMG" "$I_DIR" --ns 0xFFFF >/dev/null

# CONTROL: the file lock again, with the re-attach never detected
# (reattach_after_fence_force=0, the pre-fix behaviour): the write-open
# must go through over the holder -- or the stall did not stage the race.
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1
"$NPOKE" "$IMG" 1 --inc 100 >/dev/null
INODE_LOCK_POKE_INC=100 "$LPOKE" "$IMG" "$I_LOCK" 1 1 >/dev/null
ct_param_set reattach_after_fence_force 0
RC="$(reattach_during true python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/lockf")"
ct_param_set reattach_after_fence_force -1
L="$(lockf "$I_LOCK")"
log "control: open rc=$RC; $L"
[ "$RC" = 0 ] && ! grep -q "owner=1 mode=1" <<<"$L" &&
    pass "control: undetected and not re-taken, the write-open takes the lock -- the staging reaches the swap" ||
    fail "setup: even undetected the open did not take the lock (rc=$RC, $L) -- section 1 proves nothing"

# Clean up: row 1 leaves, its claims go with it.
"$NPOKE" "$IMG" 1 0 00 0 >/dev/null 2>&1 || true
ct_umount "$MNT"
ct_exit
