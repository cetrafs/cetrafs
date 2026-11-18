#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every bitmap sector carries its own checksum: a damaged one is caught, never used, and repaired by fsck -r
#
# A flipped bit in a data bitmap was a double allocation found only by
# an offline fsck, and the inode bitmap the same (audit 2026-11-15
# section 8). Each 512-byte bitmap sector now ends in a trailer with its
# own CRC32C, written in the same atomic sector as the bits it covers.
#
#   1. a data-bitmap sector whose bits and checksum disagree: fsck
#      reports it; the kernel counts it (bmap_crc_bad) and allocates
#      around it -- writes still succeed, and no block it describes is
#      handed out; fsck -r rewrites it and the volume checks clean;
#   2. the same for an inode-bitmap sector: creates still succeed, at
#      numbers outside the damaged sector; fsck -r repairs it;
#   3. a bit changed WITH its checksum restamped is not damage: nothing
#      is counted (the check is the checksum, not a guess at the bits).
#
# DISCRIMINATION: with cetrafs_bmap_sectors_ok() returning true, 1 and 2
# count nothing and allocate inside the damaged sector; with
# cetrafs_bmap_bad_us() returning 0, fsck reports neither.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper corrupt_poke)"
SB_POKE="$(ct_helper sb_poke)"

DEV="$(ct_dev 700 bmapcrc)"
MNT="$(ct_mnt bmapcrc)"
ct_track mnt "$MNT"
# bmap_crc_bad counts for the whole module, like every procfs counter:
# each case reads its change across its own mount, through a clean
# volume kept mounted for the whole suite so there is a reading before.
SDEV="$(ct_dev 560 bmapcrcs)"
SMNT="$(ct_mnt bmapcrcs)"
ct_track mnt "$SMNT"
ct_mkfs_small "$SDEV" >/dev/null
ct_mount "$SDEV" "$SMNT"
bad_now() { sed -n "s/^bmap_crc_bad: //p" "$(ct_procdir "$SDEV")/info"; }
field() { "$SB_POKE" "$DEV" | sed -n "s/^$1=//p"; }
SECTOR_BITS=3968

fresh() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 16384 -f >/dev/null
}
fsck_clean() { ! ct_fsck "$DEV" 2>&1 | grep -qE '^ERR'; }

log "1: a data-bitmap sector that fails its checksum"
fresh
# Bit 100 of BG 0: inside sector 0 of its bitmap, free on a new volume.
CORRUPT_POKE_RAW=1 "$POKE" "$DEV" bitset 0 100 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR: data bitmap at block .* fail their checksum' <<<"$OUT" &&
    pass "1: fsck reports the damaged data-bitmap sector" ||
    fail "1: fsck does not report it: $(grep -E '^ERR' <<<"$OUT" | head -2)"
MARK="$(dmesg_mark)"
B0="$(bad_now)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=1M count=8 conv=fsync status=none &&
    pass "1: a write still succeeds" || fail "1: the write failed"
D=$(($(bad_now) - B0))
[ "$D" -gt 0 ] && dmesg_since "$MARK" | grep -q "bitmap block .* fails its checksum" &&
    pass "1: the kernel counts the damaged sector (+$D) and says so" ||
    fail "1: bmap_crc_bad +$D, dmesg: $(dmesg_since "$MARK" | grep cetrafs | tail -2)"
# BG 0's data region: its start, from bg_map, plus the header's
# off_data_region (bytes 8..11 of the header block).
BG0="$("$(ct_helper bg_map)" "$DEV" | sed -n 's/^bg 0 .* start=\([0-9]*\) .*/\1/p')"
DSTART="$((BG0 + $(od -An -tu4 -j $((BG0 * 4096 + 8)) -N4 "$DEV" | tr -d ' ')))"
LOW="$(filefrag -v -b4096 "$MNT/f" 2>/dev/null | awk -v lim="$SECTOR_BITS" -v ds="${DSTART:-0}" \
    '$1 ~ /^[0-9]+:$/ { sub(/\.\..*/, "", $4); if ($4 + 0 - ds < lim * 8) n++ } END { print n + 0 }')"
[ "$DSTART" -gt 0 ] && [ "$LOW" = 0 ] &&
    pass "1: no block the damaged bitmap block describes was handed out" ||
    fail "1: $LOW extent(s) start in the damaged bitmap block's range (data start '${DSTART}')"
ct_umount "$MNT"
OUT="$(ct_fsck -r "$DEV" 2>&1 || true)"
fsck_clean && pass "1: fsck -r rewrites it, and the volume checks clean" ||
    fail "1: after fsck -r: $(ct_fsck "$DEV" 2>&1 | grep -E '^ERR' | head -2)"

log "2: an inode-bitmap sector that fails its checksum"
fresh
IB="$(field inode_bmap_start)"
# Byte 100 of the inode bitmap: inodes 801..808, inside sector 0, free.
printf '\x01' | dd of="$DEV" bs=1 seek=$((IB * 4096 + 100)) conv=notrunc status=none
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR: inode bitmap at block .* fail their checksum' <<<"$OUT" &&
    pass "2: fsck reports the damaged inode-bitmap sector" ||
    fail "2: fsck does not report it: $(grep -E '^ERR' <<<"$OUT" | head -2)"
B0="$(bad_now)"
ct_mount "$DEV" "$MNT"
for i in $(seq 1 20); do : >"$MNT/c$i"; done && pass "2: creates still succeed" || fail "2: a create failed"
MIN="$(stat -c %i "$MNT"/c* | sort -n | head -1)"
D=$(($(bad_now) - B0))
[ "$MIN" -gt "$SECTOR_BITS" ] && [ "$D" -gt 0 ] &&
    pass "2: at numbers past the damaged sector (lowest $MIN), and counted (+$D)" ||
    fail "2: lowest new inode $MIN, bmap_crc_bad +$D"
ct_umount "$MNT"
ct_fsck -r "$DEV" >/dev/null 2>&1 || true
fsck_clean && pass "2: fsck -r rewrites it, and the volume checks clean" ||
    fail "2: after fsck -r: $(ct_fsck "$DEV" 2>&1 | grep -E '^ERR' | head -2)"

log "3: a bit changed with its checksum restamped"
fresh
"$POKE" "$DEV" bitset 0 100 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q 'fail their checksum' <<<"$OUT" && fail "3: fsck calls a restamped sector damaged" ||
    pass "3: fsck takes a restamped sector as valid"
grep -q 'leaked\|LEAK\|marked' <<<"$OUT" && pass "3: and reports the bit itself as what it is (a leak)" ||
    fail "3: fsck says nothing about the stray bit: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
B0="$(bad_now)"
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/g" bs=1M count=2 conv=fsync status=none
D=$(($(bad_now) - B0))
[ "$D" = 0 ] && pass "3: the kernel counts nothing" ||
    fail "3: bmap_crc_bad +$D on a valid bitmap"
ct_umount "$MNT"
ct_exit
