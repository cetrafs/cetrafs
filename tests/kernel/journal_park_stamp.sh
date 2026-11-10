#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a journal entry from before its area's last park is never replayed, and a parked area cannot be flipped DIRTY from behind
#
# A fenced node's I/O already queued at the device still lands. Its flip
# of the journal flag to DIRTY and its entry write could both land after
# a peer had replayed and parked its area CLEAN; the entry's guard still
# matched (the fence had refused its target write), so the next replay
# redid an operation that had returned -EIO (M10). The flag now carries
# a park_seq every park bumps, every entry carries the park_seq of its
# session (format 0x000A), and:
#
#  A. replay skips (and consumes) an entry from another park; control:
#     the same entry stamped with the current park is applied.
#  B. the owner's DIRTY flip is a compare-and-write on the park_seq its
#     session began at: after a peer's park it is refused, the area stays
#     CLEAN and the operation fails.
#  C. a fence finding the fenced node's area CLEAN parks it (a DIRTY flip
#     queued past the fence then miscompares, as in B); control:
#     journal_fence_park_skip leaves the park where it was.
#
# DISCRIMINATION: with the entry stamp unchecked A applies the old entry;
# with the flag written blind B's create succeeds over the park and the
# area reads DIRTY (checked 2026-11-10). C carries its own control.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_fence_park_skip ] || { skip "journal_fence_park_skip is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 jpark)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jpark)"
BLK_A="$(ct_tmp jpark-a)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

park() { "$JPOKE" "$IMG" "$1" --dump | sed -n 's/.* park=\([0-9]*\)$/\1/p'; }
state() { "$JPOKE" "$IMG" "$1" --dump | sed -n 's/^state=\([0-9]*\) .*/\1/p'; }
lsroot() { ls "$MNT" | sort | tr '\n' ' '; }

# Two states of one dirent block: A (alpha) on a dead session's entry,
# B (alpha beta) on the device.
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
TARGET_LBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
ct_umount "$MNT"
[ -n "$TARGET_LBA" ] || { fail "setup: the create journaled no dirent block"; ct_exit; }
dd if="$IMG" of="$BLK_A" bs=4096 skip="$TARGET_LBA" count=1 status=none
mount -t cetrafs "$DEV" "$MNT"
touch "$MNT/beta"
ct_umount "$MNT"

# ------------------------------------------------------------------- A
log "A: an entry from before the area's last park"
JOURNAL_POKE_PARK=7 JOURNAL_POKE_ENTRY_PARK=6 "$JPOKE" "$IMG" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT"
LS="$(lsroot)"
ct_umount "$MNT"
[ "$LS" = "alpha beta " ] && pass "A: the entry from park 6 was not applied ($LS)" ||
    fail "A: an entry from before the park was replayed: root is '$LS', not 'alpha beta '"
dmesg_since "$MARK" | grep -q "is from park 6, the area is at park 7" && pass "A: and the replay said why" ||
    fail "A: no 'from park 6' message"

log "A: control -- the same entry stamped with the current park"
JOURNAL_POKE_PARK=7 "$JPOKE" "$IMG" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null
mount -t cetrafs "$DEV" "$MNT"
LS="$(lsroot)"
ct_umount "$MNT"
[ "$LS" = "alpha " ] && pass "A: control: an entry of the current park is applied ($LS)" ||
    fail "setup: even an entry of the current park was not applied ('$LS') -- A proves nothing"
[ "$(park "$NID")" = 8 ] && pass "A: and the replay's park moved the area to park 8" ||
    fail "A: after the replay the area is at park $(park "$NID"), not 8"

# ------------------------------------------------------------------- B
log "B: a peer parks this node's area before its session's first entry"
mount -t cetrafs "$DEV" "$MNT"
P="$(park "$NID")"
[ "$(state "$NID")" = 0 ] || { fail "setup: the session already flipped its area DIRTY"; ct_umount "$MNT"; ct_exit; }
JOURNAL_POKE_PARK=$((P + 1)) "$JPOKE" "$IMG" "$NID" --claim release >/dev/null
MARK="$(dmesg_mark)"
RC=0; touch "$MNT/gamma" 2>/dev/null || RC=$?
S="$(state "$NID")"
log "B: create rc=$RC; area state=$S park=$(park "$NID")"
[ "$S" = 0 ] && pass "B: the DIRTY flip did not land over the park" ||
    fail "B: the area was flipped DIRTY over a peer's park (state=$S)"
[ "$RC" != 0 ] && pass "B: the create failed" || fail "B: the create succeeded with its journal session closed"
dmesg_since "$MARK" | grep -q "was parked by a peer since this session began" && pass "B: and the refusal is logged" ||
    fail "B: no refusal in dmesg"
ct_umount "$MNT"

# ------------------------------------------------------------------- C
PEER=$(((NID + 1) % 4))
mount -t cetrafs "$DEV" "$MNT"
for f in c1 c2; do echo "$f" >"$MNT/$f"; done
I1="$(stat -c %i "$MNT/c1")"; I2="$(stat -c %i "$MNT/c2")"
ct_umount "$MNT"
# plant <ino>: row PEER departed, holding <ino>'s lock, its area CLEAN at park 3
plant() {
    "$NPOKE" "$IMG" "$PEER" 1 bb 0 >/dev/null
    "$LPOKE" "$IMG" "$1" "$PEER" 1 >/dev/null
    JOURNAL_POKE_PARK=3 "$JPOKE" "$IMG" "$PEER" --claim release >/dev/null
    [ "$(park "$PEER")" = 3 ] && [ "$(state "$PEER")" = 0 ] || { fail "setup: row $PEER's area is not CLEAN at park 3"; ct_exit; }
}
wopen() { python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$1" 2>/dev/null; }

log "C: a fence finds the fenced node's area CLEAN"
plant "$I1"
mount -t cetrafs "$DEV" "$MNT"
MARK="$(dmesg_mark)"
RC=0; wopen "$MNT/c1" || RC=$?
dmesg_since "$MARK" | grep -q "revoked stale node $PEER" || fail "C: setup: the open did not fence row $PEER (rc=$RC)"
[ "$(park "$PEER")" = 4 ] && pass "C: the fence parked row $PEER's area (park 3 -> 4)" ||
    fail "C: row $PEER's area is at park $(park "$PEER") after its fence"
ct_umount "$MNT"

log "C: control -- journal_fence_park_skip"
plant "$I2"
ct_param_set journal_fence_park_skip 1
mount -t cetrafs "$DEV" "$MNT"
MARK="$(dmesg_mark)"
wopen "$MNT/c2" || true
ct_param_set journal_fence_park_skip 0
dmesg_since "$MARK" | grep -q "revoked stale node $PEER" || fail "C: control: setup: the open did not fence row $PEER"
[ "$(park "$PEER")" = 3 ] && pass "C: control: without the fence park the area stays at park 3" ||
    fail "C: control: the area moved to park $(park "$PEER") with the fence park off -- C proves nothing"
ct_umount "$MNT"
"$NPOKE" "$IMG" "$PEER" 0 00 0 >/dev/null
ct_exit
