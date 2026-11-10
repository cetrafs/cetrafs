#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reclaim takes a dead incarnation's claim and gives nothing back when its node re-attaches; a re-taken claim stays
#
# Reclaiming a dead node's file lock or presence bit is: judge its row
# stale, fence it, replay its journal, swap the claim away. The swap
# compared the row NUMBER only, so it could not tell the dead
# incarnation's claim from one the node took again after re-attaching;
# the reclaim re-read the row afterwards and, if it had beaten since the
# fence, gave the claim back. But a node that re-attached and had NOT
# re-taken the claim got it back too -- a lock or a presence bit no open
# of its held, refusing the file to writers until something swept it
# (F10). Every claim now carries the incarnation that took it (format
# 0x000A), and the swap compares that too.
#
# The holder is registry row 1, a departed node (stale at once) at
# incarnation 111. Its re-attach is a beat plus a new incarnation, poked
# onto its row while the reclaim is held before its swap
# (reclaim_stall_before_swap_ms).
#
#  A. lock: row 1 re-attaches but does not re-take the lock -- the
#     write-open takes it, and row 1 is not handed it back.
#  B. presence: the same for a reader bit.
#  C. control: row 1 re-attaches AND re-takes the lock (new incarnation)
#     -- the write-open is refused and the lock stays row 1's.
#
# DISCRIMINATION: with the swap comparing the row only and the
# hb_seq-based give-back (the code before 0x000A), A and B fail: the
# open is refused and the claim handed back to row 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms ] || { skip "reclaim_stall_before_swap_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 rinc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rinc)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for f in a b c; do dd if=/dev/zero of="$MNT/$f" bs=4096 count=2 conv=fsync status=none; done
IA="$(stat -c %i "$MNT/a")"; IB="$(stat -c %i "$MNT/b")"; IC="$(stat -c %i "$MNT/c")"
ME="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
ct_umount "$MNT"

# Row 1: departed, incarnation 111, holding a's lock, b's reader bit and c's lock.
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null
"$NPOKE" "$IMG" 1 --inc 111 >/dev/null
INODE_LOCK_POKE_INC=111 "$LPOKE" "$IMG" "$IA" 1 1 >/dev/null
INODE_LOCK_POKE_INC=111 "$LPOKE" "$IMG" "$IB" --reader 1 >/dev/null
INODE_LOCK_POKE_INC=111 "$LPOKE" "$IMG" "$IC" 1 1 >/dev/null
grep -q "lock_inc=111 " <<<"$("$LPOKE" "$IMG" "$IA" --incs)" && grep -q "reader_inc=1:111," <<<"$("$LPOKE" "$IMG" "$IB" --incs)" ||
    { fail "setup: the claims of incarnation 111 are not on the device"; ct_exit; }
ct_mount "$DEV" "$MNT"

wopen() { python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$1" 2>/dev/null; }
# reattach <inc> [cmd...]: inside the stall, row 1 beats at a new incarnation, then runs cmd
reattach() {
    local inc="$1"; shift
    ( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$NPOKE" "$IMG" 1 --inc "$inc" >/dev/null 2>&1; "$@" ) &
}

# ------------------------------------------------------------------- A
log "A: row 1 re-attaches without re-taking the lock"
ct_param_set reclaim_stall_before_swap_ms 2000
MARK="$(dmesg_mark)"
reattach 222 true
B=$!
RC=0; wopen "$MNT/a" || RC=$?
wait "$B" || true
ct_param_set reclaim_stall_before_swap_ms 0
dmesg_since "$MARK" | grep -q "revoked stale node 1" || { fail "A: setup: no reclaim of row 1 was attempted"; ct_exit; }
L="$("$LPOKE" "$IMG" "$IA")"
[ "$RC" = 0 ] && pass "A: the write-open took the dead incarnation's lock" ||
    fail "A: the write-open was refused (rc=$RC): $L"
grep -q "owner=1 mode=1" <<<"$L" && fail "A: the lock was handed back to row 1, which never re-took it: $L" ||
    pass "A: row 1 was not handed a lock no open of its holds"
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null; "$NPOKE" "$IMG" 1 --inc 111 >/dev/null # departed again

# ------------------------------------------------------------------- B
log "B: row 1 re-attaches without re-opening the file it read"
ct_param_set reclaim_stall_before_swap_ms 2000
reattach 333 true
B=$!
RC=0; wopen "$MNT/b" || RC=$?
wait "$B" || true
ct_param_set reclaim_stall_before_swap_ms 0
R="$("$LPOKE" "$IMG" "$IB")"
[ "$RC" = 0 ] && pass "B: the write-open went ahead past the dead incarnation's reader bit" ||
    fail "B: the write-open was refused (rc=$RC): $R"
grep -qE 'readers=0x(2|3|6|7|a|b|e|f)$' <<<"$R" && fail "B: row 1's reader bit was put back: $R" ||
    pass "B: row 1's reader bit stayed cleared"
"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null; "$NPOKE" "$IMG" 1 --inc 111 >/dev/null

# ------------------------------------------------------------------- C
log "C: control -- row 1 re-attaches and takes the lock again"
ct_param_set reclaim_stall_before_swap_ms 2000
reattach 444 env INODE_LOCK_POKE_INC=444 "$LPOKE" "$IMG" "$IC" 1 1
B=$!
RC=0; wopen "$MNT/c" || RC=$?
wait "$B" || true
ct_param_set reclaim_stall_before_swap_ms 0
L="$("$LPOKE" "$IMG" "$IC")"
[ "$RC" != 0 ] && pass "C: the write-open was refused: a live incarnation holds the lock" ||
    fail "C: the write-open took a lock row 1 holds at its new incarnation"
grep -q "owner=1 mode=1" <<<"$L" && grep -q "lock_inc=444 " <<<"$("$LPOKE" "$IMG" "$IC" --incs)" &&
    pass "C: and the lock is still row 1's, incarnation 444" || fail "C: the re-taken lock was disturbed: $L"

"$LPOKE" "$IMG" "$IC" 0xFFFF 0 >/dev/null
"$NPOKE" "$IMG" 1 0 00 0 >/dev/null
ct_umount "$MNT"
ct_exit
