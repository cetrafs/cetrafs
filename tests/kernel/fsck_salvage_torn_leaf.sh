#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r salvages a regular file's extent leaf torn by media damage
#
# A leaf that fails its tail checksum used to take the whole file with
# it: every read of its range -EIO, and fsck -r refused to repair
# anything, since the file's blocks could not be told from leaked ones.
# A crash can no longer tear a leaf (it is a journal target; see
# leaf_boundary_journaled), but the media can. fsck -r now keeps each
# entry whose blocks are in a data region, set in the bitmap and named
# by nothing else, and whose logical range overlaps nothing; the rest
# become holes (userspace/fsck.c, fsck_salvage_leaves()).
#
# The damage: one 512-byte sector of the leaf zeroed (entries 63..95
# lost, the tail intact -- still a leaf), and before that one surviving
# entry pointed at ANOTHER file's block. Entry 95 crosses into the next
# sector: its logical block is zeroed and its physical run intact, a
# plausible extent naming logical 0 with another block's data -- the
# salvage must drop it too. Then:
#   - fsck reports the torn leaf; fsck -r salvages it; a second fsck is
#     clean (no cross-link, no leak);
#   - the entry naming the other file's block was dropped: that block
#     still belongs to the other file only, and its logical range in
#     the salvaged file reads zeros;
#   - every written block of the salvaged file reads its own pattern or
#     zeros -- never EIO, never another file's bytes -- and the blocks
#     of the entries the damage spared read their pattern.
#
# DISCRIMINATION: with fsck.c from before the salvage, fsck -r refuses
# and the file reads EIO; with the salvage keeping entries without the
# "named by nothing else" test, the other file's block is kept and the
# second fsck reports a cross-file overlap.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LP="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 salv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt salv)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0

NB=64 # written blocks 0, 4, ..., 4*(NB-1): about 2*NB extents, one leaf
python3 - "$MNT/a" "$NB" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(int(sys.argv[2]) * 4 * 4096)) == 0
for i in range(int(sys.argv[2])):
    os.pwrite(fd, (b"A%07d" % (i * 4)) * 512, i * 4 * 4096)
os.fsync(fd)
os.close(fd)
PY
python3 -c 'import os,sys; open(sys.argv[1],"wb").write(b"BBBBBBBB" * 512); os.sync()' "$MNT/b"
AI="$(stat -c %i "$MNT/a")"
BPHYS="$(filefrag -v -b4096 "$MNT/b" | awk '$1 == "0:" { sub(/\.\..*/, "", $4); print $4; exit }')"
ct_umount "$MNT"

[ -n "$BPHYS" ] && [ "$BPHYS" -gt 0 ] 2>/dev/null || { fail "setup: no physical block for b"; ct_exit; }
L="$("$LP" "$IMG" leaf "$AI" 2>/dev/null || true)"
[ -n "$L" ] && [ "$L" -gt 0 ] 2>/dev/null || { fail "setup: file a has no leaf"; ct_exit; }
SHOW="$("$LP" "$IMG" show "$AI")"
NENT="$(grep -c '^ent ' <<<"$SHOW")"
[ "$NENT" -gt 100 ] || { fail "setup: the leaf holds $NENT entries; the damage needs more than 100"; ct_exit; }
# The first WRITTEN entry: pointed at b's block. Its logical block must
# read zeros after the salvage, not b's bytes.
read -r K KBLK < <(awk '/^ent / && / uninit=0/ { sub(/ent /, ""); sub(/block=/, "", $2); print $1, $2; exit }' <<<"$SHOW")
[ -n "${K:-}" ] && [ "$K" -lt 63 ] || { fail "setup: no written entry below the damaged sector"; ct_exit; }
"$LP" "$IMG" setphys "$AI" "$K" "$BPHYS" >/dev/null
# Media damage: sector 2 of the leaf (bytes 1024..1535; entries 63..95).
dd if=/dev/zero of="$IMG" bs=512 seek=$((L * 8 + 2)) count=1 conv=notrunc status=none
log "file a ino $AI: leaf $L, $NENT entries; entry $K (logical $KBLK) -> b's block $BPHYS; sector 2 zeroed"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $AI's extent leaf (block $L) failed its tail checksum" <<<"$OUT" &&
    pass "setup: fsck sees the torn leaf" ||
    { fail "setup: fsck did not report the torn leaf: $(grep '^ERR' <<<"$OUT" | head -3)"; ct_exit; }

OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
grep -q "salvaged inode $AI's extent leaf (block $L)" <<<"$OUT" &&
    pass "fsck -r salvaged it: $(grep -o "kept [0-9]* of [0-9]* extent(s)" <<<"$OUT")" ||
    fail "fsck -r did not salvage the leaf: $(grep -E '^(ERR|NOTE)|refus' <<<"$OUT" | head -4)"

OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" &&
    pass "a second fsck is clean: nothing shared, nothing leaked" ||
    fail "a second fsck still finds: $(grep '^ERR' <<<"$OUT" | head -3)"

ct_mount "$DEV" "$MNT"
RES="$(python3 - "$MNT/a" "$NB" "$KBLK" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
nb, kblk = int(sys.argv[2]), int(sys.argv[3])
good = holes = 0
bad = []
for i in range(nb):
    b = i * 4
    try:
        d = os.pread(fd, 4096, b * 4096)
    except OSError as e:
        bad.append("%d:%s" % (b, e.strerror))
        continue
    if d == (b"A%07d" % b) * 512:
        good += 1
    elif d == b"\0" * 4096:
        holes += 1
    else:
        bad.append("%d:foreign(%r)" % (b, d[:8]))
k = os.pread(fd, 4096, kblk * 4096)
print(good, holes, "kzero" if k == b"\0" * 4096 else "kNONZERO", " ".join(bad[:6]).replace(" ", "_"))
PY
)"
read -r GOOD HOLES KZ BAD <<<"$RES"
[ -z "${BAD:-}" ] && pass "every written block reads its own pattern or zeros ($GOOD intact, $HOLES now holes)" ||
    fail "blocks unreadable or holding foreign bytes: $BAD"
[ "$KZ" = kzero ] && pass "the entry that named b's block was dropped: its range reads zeros" ||
    fail "the salvaged file reads something other than zeros at logical $KBLK, where the dropped entry was"
[ "$GOOD" -ge $((NB / 2)) ] && pass "the blocks the damage spared survived ($GOOD of $NB)" ||
    fail "only $GOOD of $NB written blocks survived the salvage"
[ "$(head -c 8 "$MNT/b")" = BBBBBBBB ] && pass "b still reads its own data" || fail "b's data changed"
ct_umount "$MNT"
ct_exit
