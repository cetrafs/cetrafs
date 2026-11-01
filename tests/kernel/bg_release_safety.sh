#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a released Block Group is provably empty on its bitmap and nothing of ours lands on it afterwards
#
# Releasing a Block Group hands it to whoever claims it next, who reads
# its bitmap off the device and allocates from it. Two ways that went
# wrong:
#
#  A. The decision. cetrafs_bg_release_empty()'s comment promised that
#     "the authoritative bitmap scan below still decides" -- there was no
#     scan: the free COUNT decided, and a count is a cache (one too high
#     was, until ecfd0ea, the steady state of a claimed Block Group). An
#     overstated count released a Block Group holding live data. With
#     the count checks switched off, the bitmap must refuse on its own.
#
#  B. The handover. Frees clear bitmap bits with sync=false, so at
#     release time this node's cached bitmap block could still be dirty.
#     The release CAS went out, a peer claimed the Block Group and wrote
#     its own allocations into that bitmap -- and then this node's
#     writeback put its stale image (all clear) back on top of them.
#     Every block the peer had allocated read FREE again.
#
#  C. The same handover for a whole surplus Zone Group, which also had
#     no drain: an allocation could land between its emptiness check and
#     its release CAS.
#
# B and C play the peer by setting bits in the released bitmap on the
# device, then make this node write back.
#
# DISCRIMINATION (measured on the unfixed code): A releases all three
# Block Groups with live data in them; B and C find the peer's bits
# wiped.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 1700 bgrelsafe)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt bgrelsafe)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
nbg="$(ct_bgs_of_zg "$DEV" 0 | wc -l)"
[ "$nbg" -ge 3 ] && pass "Zone Group 0 owns $nbg Block Groups" || { fail "only $nbg Block Groups"; ct_exit; }
compress_timing

bg_owner() { "$MAP" "$DEV" | awk -v b="$1" '$1 == "bg" && $2 == b {split($3,a,"="); print a[2]}'; }
bg_start() { "$MAP" "$DEV" | awk -v b="$1" '$1 == "bg" && $2 == b {split($4,a,"="); print a[2]}'; }

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Fill every Block Group, so each holds data.
mkdir "$MNT/bulk"
i=0
while dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 300 ] && break
done
sync
[ "$i" -gt 20 ] && pass "filled the volume ($i files)" || fail "only $i files written"

# ---------------------------------------------------------------- A
log "A: the count checks switched off -- only the bitmap may stand in the way"
# Every Block Group is full here, so ANY release hands live data away.
# A count that wrongly says "empty" cannot be planted from outside on a
# single node (an owned descriptor is served from this node's cache, by
# design), so the test-only switch removes the count checks instead.
ct_param_set bg_release_skip_empty_check 1
sleep 5 # several 1 s release ticks
ct_param_set bg_release_skip_empty_check 0
gone="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | tr '\n' ' ')"
if [ -z "$gone" ]; then
    pass "A: no Block Group holding data was released -- the bitmap refused every one"
else
    fail "A: Block Group(s) $gone RELEASED with live data in them"
fi

# ---------------------------------------------------------------- B
log "B: empty the volume WITHOUT syncing, so the bitmaps are dirty at release"
rm -rf "$MNT/bulk"
if wait_for 30 '[ -n "$(ct_bgs_of_zg "'"$DEV"'" '"$FREE_MARK"' 2>/dev/null)" ]' 2>/dev/null; then
    REL="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | head -1)"
    pass "B: BG $REL was released after the delete"
else
    fail "B: nothing was released -- the handover is not exercised"
    ct_exit
fi

# The peer: claims the released Block Group and allocates in it, which
# lands in its bitmap on the device. 64 blocks, a recognisable pattern.
BMAP_LBA=$(($(bg_start "$REL") + 1))
python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b'\xff' * 8, int(sys.argv[2]) * 4096 + 512)
os.fsync(fd)" "$BACK" "$BMAP_LBA"

# This node writes back whatever it still holds dirty.
sync
ct_umount "$MNT"
got="$(python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(os.pread(fd, 8, int(sys.argv[2]) * 4096 + 512).hex())" "$BACK" "$BMAP_LBA")"
if [ "$got" = "ffffffffffffffff" ]; then
    pass "B: the peer's allocations in the released bitmap survived this node's writeback"
else
    fail "B: this node's writeback wiped the peer's allocations in BG $REL's bitmap (now $got)"
fi

# ---------------------------------------------------------------- C
# The same handover one level up: a whole Zone Group given back as
# surplus. Its member Block Groups go with it, and the next owner
# reconciles their counts from the bitmaps on the device -- so the same
# dirty-bitmap writeback lands on top of that owner's allocations.
log "C: a surplus Zone Group given back with dirty member bitmaps"
# The per-Block-Group release runs first on every tick and would hand
# back each emptied member on its own -- leaving the Zone Group release
# nothing to hand over. Switched off, so it is the path measured here.
ct_param_set bg_release_off 1
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/bulk"
i=0
while dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 300 ] && break
done
sync
owned_zgs() { "$MAP" "$DEV" | awk '/^zg /{split($3,a,"="); if (a[2]+0 != 65535) n++} END{print n+0}'; }
[ "$(owned_zgs)" -ge 2 ] && pass "C: the fill made this node own $(owned_zgs) Zone Groups" ||
    { fail "C: only $(owned_zgs) Zone Group(s) owned -- no surplus to give back"; ct_exit; }
rm -rf "$MNT/bulk"
if wait_for 30 '[ "$(owned_zgs)" -lt 2 ]' 2>/dev/null; then
    RZ="$("$MAP" "$DEV" | awk '/^zg /{split($3,a,"="); if (a[2]+0 == 65535) {print $2; exit}}')"
    pass "C: Zone Group $RZ was given back after the delete"
else
    fail "C: no Zone Group was given back -- the handover is not exercised"
    ct_exit
fi
RB="$(ct_bgs_of_zg "$DEV" "$RZ" | head -1)"
if [ -n "$RB" ]; then
    pass "C: Zone Group $RZ went with its member Block Group $RB"
else
    fail "C: Zone Group $RZ has no member Block Group -- nothing was handed over, the measurement below would be empty"
    ct_exit
fi
ZBMAP=$(($(bg_start "$RB") + 1))
python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b'\xff' * 8, int(sys.argv[2]) * 4096 + 512)
os.fsync(fd)" "$BACK" "$ZBMAP"
sync
ct_umount "$MNT"
got="$(python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(os.pread(fd, 8, int(sys.argv[2]) * 4096 + 512).hex())" "$BACK" "$ZBMAP")"
if [ "$got" = "ffffffffffffffff" ]; then
    pass "C: the next owner's allocations in BG $RB (ZG $RZ) survived this node's writeback"
else
    fail "C: this node's writeback wiped the next owner's allocations in BG $RB of released ZG $RZ (now $got)"
fi

ct_exit
