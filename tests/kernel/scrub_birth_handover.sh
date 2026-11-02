#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create that meets a peer's reclaim of the same inode number ends with the bit owned or clear, never orphaned
#
# A reclaim (a peer's orphan scrub, or a peer's evict) frees an inode
# number in three swaps: CLAIM the dead record, CLEAR the bit, RELEASE
# the record. A creator takes a number by setting its bit, then reads the
# record and claims it for the birth. Two interleavings were wrong:
#
#  (a) The reclaim has claimed and CLEARED, not yet released, when the
#      creator sets the bit. The creator read the reclaim's lock and
#      walked away, leaving "the bit to the reclaim" -- which had already
#      cleared it and never would again. The number stayed allocated
#      under a dead record whose extents name blocks the same scrub cycle
#      had freed and the allocator handed to other files: a three-node
#      hypervisor-storm run ended with fsck reporting "referenced by more
#      than one inode" on exactly the numbers the creator had logged as
#      abandoned, twice in two runs.
#
#  (b) The reclaim judges the creator's freshly set bit an orphan and
#      runs its whole claim-clear-release before the creator reads the
#      record. The creator then reads the RELEASED record, its birth
#      claim lands, and it owns a number whose bit is clear.
#
# The fix: in (a) the creator waits for the release and then reads the
# bit fresh -- set means it is the creator's to claim; in (b) the creator
# re-reads the bit once its claim is held (no reclaim can claim past it)
# and gives the claim back if the bit is clear.
#
# The peer's reclaim is played on the backing file, by the protocol, in
# test-only pauses of the allocation.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SBPOKE="$(ct_helper sb_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_dev 560 birthhand)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt birthhand)"
ct_mkfs_small "$DEV" >/dev/null
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$LPOKE" "$BACK" 1 >/dev/null # warm the helper build outside any gap

bit() { # <ino> [0|1] -- read, or set, the inode's bit in the backing file
    python3 - "$BACK" "$IBM" "$1" "${2:-}" <<'PY'
import os, sys
back, ibm, ino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
b = ino - 1
off = ibm * 4096 + b // 8
fd = os.open(back, os.O_RDWR)
v = os.pread(fd, 1, off)[0]
if sys.argv[4] == "":
    print((v >> (b % 8)) & 1)
else:
    v = (v | (1 << (b % 8))) if sys.argv[4] == "1" else (v & ~(1 << (b % 8)))
    os.pwrite(fd, bytes([v]), off)
    os.fsync(fd)
os.close(fd)
PY
}

# dead_number <name> -> an inode number whose record is dead (checksummed,
# nlink 0) and whose bit is clear: the lowest free number, so the next
# create takes it.
dead_number() {
    touch "$MNT/$1"
    sync
    local n
    n="$(stat -c %i "$MNT/$1")"
    rm "$MNT/$1"
    sync
    echo "$n"
}

claim() { "$LPOKE" "$BACK" "$1" --ns 7 >/dev/null; "$IPOKE" "$BACK" bumpseq "$1" 2>/dev/null; }
release() { "$LPOKE" "$BACK" "$1" --ns 65535 >/dev/null; "$IPOKE" "$BACK" bumpseq "$1" 2>/dev/null; }

# verdict <case> <N> <created-file>: the number ends with one owner or none.
verdict() {
    local c="$1" n="$2" f="$3" got b
    got=""
    [ -e "$MNT/$f" ] && got="$(stat -c %i "$MNT/$f")"
    b="$(bit "$n")"
    if [ "$got" = "$n" ] && [ "$b" = 1 ]; then
        pass "($c) ino $n: the create owns it and its bit is set"
    elif [ "$got" != "$n" ] && [ "$b" = 0 ]; then
        pass "($c) ino $n: the create took ino ${got:-none} and $n is free"
    elif [ "$got" = "$n" ]; then
        fail "($c) the create owns ino $n but its bit is CLEAR: the next create anywhere takes it too"
    else
        fail "($c) ino $n is allocated but the create took ino ${got:-none}: the number was left to nobody"
    fi
}

# ---------------------------------------------------------------- (a)
log "(a) the reclaim has claimed and cleared, not yet released, when the create takes the number"
N="$(dead_number olda)"
claim "$N" # claim; its clear is a no-op here, the bit is already clear
ct_param_set birth_gap_ms 300 # hold the create after its record read
( touch "$MNT/newa" ) &
CPID=$!
sleep 0.15
held="$(bit "$N")"
if [ "$held" = 1 ] && grep -q ' ns_owner=7 ' <<<"$("$LPOKE" "$BACK" "$N")"; then
    pass "(a) set up: the create holds ino $N's bit while the reclaim still holds its record"
else
    fail "(a) not set up: bit=$held lock='$("$LPOKE" "$BACK" "$N")' -- the create did not take ino $N under the claim"
fi
sleep 0.5
release "$N"
wait "$CPID" || true
ct_param_set birth_gap_ms 0
verdict a "$N" newa

# ---------------------------------------------------------------- (b)
log "(b) the reclaim runs its whole cycle on the create's fresh bit before the create reads the record"
N="$(dead_number oldb)"
ct_param_set birth_read_gap_ms 1500
( touch "$MNT/newb" ) &
CPID=$!
sleep 0.3
held="$(bit "$N")"
if [ "$held" = 1 ] && grep -q ' nlink=0 ' <<<"$("$LPOKE" "$BACK" "$N" --rec)"; then
    pass "(b) set up: the create holds ino $N's bit and has not read the dead record yet"
    claim "$N"
    bit "$N" 0
    release "$N"
else
    fail "(b) not set up: bit=$held -- the create did not take ino $N"
fi
wait "$CPID" || true
ct_param_set birth_read_gap_ms 0
verdict b "$N" newb

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! grep -qE '^(ERR|WARN)' <<<"$out"; then
    pass "fsck clean: no orphan, no number in use with a clear bit"
else
    fail "fsck rc=$rc: $(grep -E '^(ERR|WARN)' <<<"$out" | head -4)"
fi

ct_exit
