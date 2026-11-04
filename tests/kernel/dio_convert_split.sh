#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an O_DIRECT write converting a run inside an array with ONE free slot
#
# An O_DIRECT write into preallocated space converts its whole range at
# completion, a run at a time (cetrafs_dio_end_io()). A run strictly
# inside a preallocated extent splits it in three -- head, written run,
# tail -- which needs two free slots. With exactly one free,
# cetrafs_leaf_array_convert() puts the tail in that slot and hands the
# written blocks back to be appended through the tree. It reported the
# whole run done and the caller appended ONE block: every other block of
# the write was in no extent, its data on the device, the file reading
# zeros there, its blocks leaked. Buffered writes and faults convert one
# block at a time, so before O_DIRECT stayed direct nothing asked this
# branch for more than one.
#
# One free slot is arranged exactly and asserted before the write: the
# record's inline array at 3 of 4 (depth 0), and a leaf at 253 of 254
# (depth 1).
#
# DISCRIMINATION: with the fix reverted (`*done = count` and the tail at
# iblock + count in the one-free-slot branch), both depths read 255 of
# the 256 written blocks back as zeros. fsck stays clean then: the lost
# blocks are allocated and unreferenced, a leak it does not count as an
# error, so the read-back is the only witness.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dio_fill_holes ] || { skip "dio_fill_holes is missing"; ct_exit; }

POKE="$(ct_helper inode_block_poke)"
LEAF="$(ct_helper leaf_poke)"
IMG="$(ct_image 560 dioconv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dioconv)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }
ct_param_set auto_defrag 0
ct_param_set dio_fill_holes 1

# Every block is stamped with its own number, whichever path wrote it.
PY_COMMON='
import os, sys, mmap, ctypes
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
def ab(n, align=4096):
    b = mmap.mmap(-1, n + align)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % align
'
falloc() { python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o644); os.posix_fallocate(fd,0,int(sys.argv[2])); os.close(fd)' "$1" "$2"; }
# bufw <file> <block>: one buffered 4 KiB write, fsynced -- converts one
# block, which splits its extent.
bufw() {
    python3 -c "$PY_COMMON"'
fd = os.open(sys.argv[1], os.O_RDWR); i = int(sys.argv[2])
os.pwrite(fd, stamp(i), i * 4096); os.fsync(fd); os.close(fd)' "$1" "$2"
}
# diow <file> <first> <n>: ONE O_DIRECT write of n blocks.
diow() {
    python3 -c "$PY_COMMON"'
p, first, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
b, o = ab(n * 4096)
for k in range(n): b[o + k * 4096:o + (k + 1) * 4096] = stamp(first + k)
fd = os.open(p, os.O_RDWR | os.O_DIRECT)
assert os.pwrite(fd, memoryview(b)[o:o + n * 4096], first * 4096) == n * 4096
os.fsync(fd); os.close(fd)' "$1" "$2" "$3"
}
# check <file> <first> <n> <bufblocks-file>: the run and every buffered
# block carry their stamps, everything else in the file reads as zeros.
check() {
    python3 -c "$PY_COMMON"'
p, first, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
want = set(range(first, first + n)) | {int(x) for x in open(sys.argv[4]).read().split()}
d = open(p, "rb").read()
bad = [i for i in range(len(d) // 4096) if d[i*4096:(i+1)*4096] != (stamp(i) if i in want else b"\0" * 4096)]
zer = [i for i in bad if d[i*4096:(i+1)*4096] == b"\0" * 4096]
print("ok" if not bad else "BAD %d (%d read as zeros) first %d" % (len(bad), len(zer), bad[0]))' "$1" "$2" "$3" "$4"
}
# The record and the leaf as the device has them (the kernel writes both
# synchronously at fsync, so a read-only look is safe mounted).
rec() { "$POKE" "$IMG" extents "$1"; }
leaf_entries() {
    local lba
    lba="$("$LEAF" "$IMG" leaf "$1")"
    python3 -c 'import struct,sys; f=open(sys.argv[1],"rb"); f.seek(int(sys.argv[2])*4096+2); print(struct.unpack("<H",f.read(2))[0])' "$IMG" "$lba"
}

# ------------------------------------------------------------ depth 0
log "depth 0: the record's inline array at 3 of 4 entries"
F="$MNT/d0"
falloc "$F" $((16 << 20))
INO="$(stat -c %i "$F")"
BUF0="$(ct_tmp dioconv-buf0)"
bufw "$F" 1000
echo 1000 >"$BUF0"
sync
R="$(rec "$INO")"
if grep -q '^depth=0 entries=3 ' <<<"$R"; then
    C0="$(ctr dio_converts)"
    diow "$F" 2000 256
    C1="$(ctr dio_converts)"
    [ "$((C1 - C0))" -ge 1 ] || fail "depth 0: the O_DIRECT write converted nothing -- it did not take the path under test"
    OUT="$(check "$F" 2000 256 "$BUF0")"
    [ "$OUT" = ok ] && pass "depth 0: all 256 blocks of the run read back after a split with one free slot" ||
        fail "depth 0: $OUT"
else
    fail "depth 0: setup: wanted depth=0 entries=3 before the write, have: $R"
fi

# ------------------------------------------------------------ depth 1
# Each buffered write strictly inside a preallocated extent adds two
# entries; one at block 0 (no written neighbour) adds one, which fixes
# the parity so the count lands on 253 exactly.
log "depth 1: a leaf at 253 of 254 entries"
F1="$MNT/d1"
falloc "$F1" $((64 << 20))
INO1="$(stat -c %i "$F1")"
BUF1="$(ct_tmp dioconv-buf1)"
: >"$BUF1"
E=0
blk=8
while [ "$E" -lt 253 ] && [ "$blk" -lt 4000 ]; do
    if grep -q '^depth=1 ' <<<"$(rec "$INO1")" && [ "$E" -eq 252 ]; then
        w=0
    else
        w=$blk
        blk=$((blk + 8))
    fi
    bufw "$F1" "$w"
    echo "$w" >>"$BUF1"
    R="$(rec "$INO1")"
    if grep -q '^depth=1 entries=1 ' <<<"$R"; then
        E="$(leaf_entries "$INO1")"
    elif grep -q '^depth=0 ' <<<"$R"; then
        E=0
    else
        break
    fi
done
R="$(rec "$INO1")"
if grep -q '^depth=1 entries=1 ' <<<"$R" && [ "$E" -eq 253 ]; then
    C0="$(ctr dio_converts)"
    diow "$F1" 12000 256
    C1="$(ctr dio_converts)"
    [ "$((C1 - C0))" -ge 1 ] || fail "depth 1: the O_DIRECT write converted nothing -- it did not take the path under test"
    OUT="$(check "$F1" 12000 256 "$BUF1")"
    [ "$OUT" = ok ] && pass "depth 1: all 256 blocks of the run read back after a split with one free leaf slot" ||
        fail "depth 1: $OUT"
else
    fail "depth 1: setup: wanted one leaf at 253 entries before the write, have $R, leaf at $E"
fi

log "after a remount: what was published is what reads back"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
OUT="$(check "$MNT/d0" 2000 256 "$BUF0")"
[ "$OUT" = ok ] && pass "depth 0: the run survives a remount" || fail "depth 0, after a remount: $OUT"
OUT="$(check "$MNT/d1" 12000 256 "$BUF1")"
[ "$OUT" = ok ] && pass "depth 1: the run survives a remount" || fail "depth 1, after a remount: $OUT"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
