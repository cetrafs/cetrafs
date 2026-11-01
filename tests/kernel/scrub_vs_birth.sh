#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's orphan scrub and a local create racing for the same inode number end with one owner
#
# Between taking an inode number (bitmap CAS) and writing its record, a
# creating node leaves the number's PREVIOUS, dead record on the device:
# nlink 0, valid checksums, no locks. A peer's orphan scrub sees exactly
# that -- an allocated bit and a dead record -- and reclaims the number.
# The birth registry that stops this node's own scrub is per-node, so it
# cannot stop a peer's (the comment above cetrafs_free_inode_if_dead()
# said it closed the window; it closed it for one node only).
#
# The fix makes the RECORD the arbiter. The scrub claims the dead record
# (ns_lock_owner, by CAS against the image it judged) before it clears
# the bit, and releases it, advancing sector 0's change stamp. The creator publishes
# its record by CAS against the image it read after taking the bit, so a
# claim landing in between makes it miscompare: it abandons that number
# -- leaving the bit to the scrub that owns it -- and takes another.
#
# The test plays the peer scrub, by that protocol, inside a test-only
# pause in the allocation (birth_gap_ms, between the bit CAS and the
# birth claim -- the window the fix has to win): it claims the record
# while the create holds the number, and clears the bit and releases the
# record after the create has returned. With the fix the create abandons
# that number and takes another; fsck then finds one owner per number.
#
# DISCRIMINATION (measured on the unfixed code): the create's blind
# record write erases the claim, its still-owned check passes (the bit
# is still set), the create returns with that number -- and once the
# scrub clears the bit, fsck finds a live file whose bit reads free.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SBPOKE="$(ct_helper sb_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_dev 560 scrubbirth)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt scrubbirth)"
ct_mkfs_small "$DEV" >/dev/null
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

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

# A number with a DEAD record (a virgin all-zero record fails its
# checksum and no scrub would ever judge it).
touch "$MNT/old"
sync
N="$(stat -c %i "$MNT/old")"
rm "$MNT/old"
sync
log "ino $N now has a dead record and a clear bit"

ct_param_set birth_gap_ms 2000
"$LPOKE" "$BACK" "$N" >/dev/null # warm the helper build outside the gap
( touch "$MNT/new" ) &
CPID=$!
sleep 0.5

# Setup proof: the create holds N and its record is still the dead one.
held="$(bit "$N")"
rec="$("$LPOKE" "$BACK" "$N" --rec)"
if [ "$held" = 1 ] && grep -q ' nlink=0 ' <<<"$rec"; then
    pass "in the gap the create holds ino $N and its record is the dead one ($rec)"
else
    fail "in the gap: bit=$held record='$rec' -- the create did not take ino $N, the race is not set up"
fi

# The peer scrub, by the protocol: its claim is a CAS that lands only on
# the dead, UNLOCKED record it judged. (A blind poke over a record the
# creator has already claimed would be a scrub the fix forbids.)
lockline="$("$LPOKE" "$BACK" "$N")"
if grep -q ' ns_owner=65535 ' <<<"$lockline" && grep -q ' nlink=0 ' <<<"$("$LPOKE" "$BACK" "$N" --rec)"; then
    "$LPOKE" "$BACK" "$N" --ns 7 >/dev/null
    claimed=1
    pass "the peer scrub's claim landed on the dead record while the create held the bit"
else
    claimed=0
    fail "the record was not dead-and-unlocked in the gap ($lockline) -- the scrub never got to claim it, the race is not set up"
fi
wait "$CPID" || true

# ...and, its claim having landed, the rest of its reclaim: clear the
# bit, release the record. The release advances sector 0's change stamp
# (dirent_seq), never the generation: that is echoed into the file
# sector, and changing it in sector 0 alone makes the record read as a
# half-landed write ("checksum is wrong").
if [ "$claimed" = 1 ]; then
    bit "$N" 0
    "$LPOKE" "$BACK" "$N" --ns 65535 >/dev/null
    "$IPOKE" "$BACK" bumpseq "$N" 2>/dev/null
fi

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
if [ -e "$MNT/new" ]; then
    NEW="$(stat -c %i "$MNT/new")"
    pass "the create completed (got ino $NEW)"
else
    NEW=""
    log "the create did not complete -- acceptable, if nothing was left half-owned"
fi
ct_umount "$MNT"

rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^ERR' <<<"$out"; then
    pass "fsck clean: ino $N and the new file each have exactly one owner"
else
    fail "fsck rc=$rc after the race (new file ino ${NEW:-none}): $(grep '^ERR' <<<"$out" | head -3)"
fi

ct_exit
