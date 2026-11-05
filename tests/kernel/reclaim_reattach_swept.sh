#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reclaim whose holder re-attached and swept first keeps the free lock it took
#
# A reclaim fences a stale holder, replays its journal, then swaps the
# claim away; if the holder's row beat in between (it re-attached), the
# claim is given back (reclaim_vs_reattach.sh). But a re-attaching node
# SWEEPS its leftover claims -- that is what the sweep is for -- and the
# swap accepts a lock already free as readily as one held by the stale
# owner. Giving back a lock the swap found FREE handed the live node a
# lock no open of its holds: nothing ever released it, and every open of
# the file, or every create in the directory, was refused until that
# node unmounted. A claim now gives back only what it displaced.
#
# Staged as reclaim_vs_reattach.sh stages it: registry row 1 is a
# departed node holding the file lock and a directory's namespace lock;
# the reclaim is held between its journal replay and the swap
# (reclaim_stall_before_swap_ms) while row 1 beats AND its claim is
# cleared -- the re-attach and its sweep. (Earlier, between fence and
# replay, the replay itself sees the re-attach and refuses.)
#
# DISCRIMINATION: proven by removing the displacement test from the
# give-back conditions (lock.c open and flock, nslock.c): the write-open
# is refused and the lock left with row 1; the create times out under a
# namespace lock row 1 does not know it holds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms ] || { skip "reclaim_stall_before_swap_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
NONE=0xFFFF

IMG="$(ct_image 560 rrs)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rrs)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
dd if=/dev/zero of="$MNT/lockf" bs=4096 count=4 conv=fsync status=none
I_LOCK="$(stat -c %i "$MNT/lockf")"
I_DIR="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"

"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1 || fail "setup: could not register row 1"
"$LPOKE" "$IMG" "$I_LOCK" 1 1 >/dev/null
"$LPOKE" "$IMG" "$I_DIR" --ns 1 >/dev/null
L="$("$LPOKE" "$IMG" "$I_LOCK")"
grep -q "owner=1 mode=1" <<<"$L" || { fail "setup: the file lock is not row 1's: $L"; ct_exit; }
ct_mount "$DEV" "$MNT"

# 1. The file lock. Inside the stall: row 1 beats, then clears its lock.
ct_param_set reclaim_stall_before_swap_ms 2000
( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$LPOKE" "$IMG" "$I_LOCK" "$NONE" 0 >/dev/null 2>&1 ) &
B=$!
RC=0
python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/lockf" 2>/dev/null || RC=$?
wait "$B" || true
ct_param_set reclaim_stall_before_swap_ms 0
L="$("$LPOKE" "$IMG" "$I_LOCK")"
log "lock: open rc=$RC; $L"
dmesg | tail -40 | grep -q "revoked stale node 1" ||
    { fail "setup: no reclaim of row 1 was attempted -- this proves nothing"; ct_exit; }
[ "$RC" = 0 ] && pass "lock: the write-open took the lock the sweep had freed" ||
    fail "lock: the write-open was refused (rc=$RC) over a lock nobody held"
grep -q "owner=1 mode=1" <<<"$L" &&
    fail "lock: the freed lock was 'given back' to row 1, which holds no open of it: $L" ||
    pass "lock: row 1 was not handed a lock it never re-took ($L)"
RC=0
python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/lockf" 2>/dev/null || RC=$?
[ "$RC" = 0 ] && pass "lock: the file opens for writing again" || fail "lock: the file is wedged (rc=$RC)"

"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1

# 2. The namespace lock. Inside the stall: row 1 beats, then clears it.
ct_param_set reclaim_stall_before_swap_ms 2000
( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$LPOKE" "$IMG" "$I_DIR" --ns "$NONE" >/dev/null 2>&1 ) &
B=$!
RC=0
timeout 25 touch "$MNT/d/new" 2>/dev/null || RC=$?
wait "$B" || true
ct_param_set reclaim_stall_before_swap_ms 0
L="$("$LPOKE" "$IMG" "$I_DIR")"
log "nslock: create rc=$RC; $L"
[ "$RC" = 0 ] && pass "nslock: the create went through on the lock the sweep had freed" ||
    fail "nslock: the create did not complete (rc=$RC) -- the directory is wedged"
grep -q "ns_owner=1 " <<<"$L" &&
    fail "nslock: the freed namespace lock was 'given back' to row 1: $L" ||
    pass "nslock: row 1 was not handed a namespace lock it never re-took"
dmesg | tail -40 | grep -q "came back while its" &&
    fail "a give-back was logged for a lock nothing displaced" || pass "no give-back was logged"

"$NPOKE" "$IMG" 1 0 00 0 >/dev/null 2>&1 || true
ct_umount "$MNT"
ct_exit
