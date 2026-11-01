#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory growing into a block a live directory still lists refuses, and the names survive
#
# cetrafs_dirent_block_init() zeroes a block the allocator has just
# handed to a growing directory. It carried a guard for the case where
# the allocator is wrong -- the block still belongs to a live directory
# -- but the guard had two holes:
#
#  - it judged the block from cetrafs_getblk_overwrite(), which never
#    reads the device: it inspected whatever the page cache happened to
#    hold (nothing, on a cold cache), not what is on the disk;
#  - when it DID catch a live directory, it printed an error and zeroed
#    the block anyway, destroying every name in it on every node.
#
# The test plants exactly that allocator fault: directory A's first
# block keeps its names and its extent but reads FREE in the bitmap
# (counts adjusted to match), on an otherwise full volume, so the next
# directory to grow is handed A's block. With the fix the growth is
# refused, the block stays allocated (the bitmap now agrees with the
# extent), and A keeps its names.
#
# DISCRIMINATION (measured on the unfixed code): the growth succeeds
# into A's block; A's names are gone and A lists B's new entry instead.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

MAP="$(ct_helper bg_map)"
BGPOKE="$(ct_helper bg_poke)"
IPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_dev 560 direntlive)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt direntlive)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0 # no speculative runs: the fill must leave nothing free
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/A" "$MNT/B"
for i in 1 2 3 4 5; do touch "$MNT/A/f$i"; done
# B's first block: '.', '..' and 13 names fill it, so B's next name grows B.
for i in $(seq 1 13); do touch "$MNT/B/b$i"; done
ino_a="$(stat -c %i "$MNT/A")"
ino_b="$(stat -c %i "$MNT/B")"
i=0
while dd if=/dev/zero of="$MNT/fill$i" bs=1M count=64 status=none 2>/dev/null; do i=$((i + 1)); done
sync
ct_umount "$MNT"

ext_a="$("$IPOKE" "$BACK" extents "$ino_a")"
ext_b="$("$IPOKE" "$BACK" extents "$ino_b")"
LBA="$(awk '/^ext 0 /{split($4,a,"="); print a[2]}' <<<"$ext_a")"
if [ -n "$LBA" ] && grep -q '^depth=0 entries=1 ' <<<"$ext_b" && grep -q 'len=1$' <<<"$ext_b"; then
    pass "A's first block is $LBA; B is exactly one full block"
else
    fail "setup: A='$ext_a' B='$ext_b' -- the layout this test needs was not produced"
    ct_exit
fi

# Find A's block's Block Group and clear its bit; the counts follow.
BG="$(python3 - "$BACK" "$LBA" "$("$MAP" "$DEV")" <<'PY'
import os, struct, sys
back, lba = sys.argv[1], int(sys.argv[2])
fd = os.open(back, os.O_RDWR)
for line in sys.argv[3].splitlines():
    f = line.split()
    if f[0] != "bg":
        continue
    start = int(f[3].split("=")[1])
    hdr = os.pread(fd, 24, start * 4096)
    length, off_bmap, off_data = struct.unpack_from("<QII", hdr, 8)
    if not (start + off_data <= lba < start + length):
        continue
    bit = lba - start - off_data
    off = (start + off_bmap) * 4096 + bit // 8
    v = os.pread(fd, 1, off)[0]
    assert v & (1 << (bit % 8)), "bit already clear"
    os.pwrite(fd, bytes([v & ~(1 << (bit % 8))]), off)
    os.fsync(fd)
    print(f[1])
    break
PY
)"
[ -n "$BG" ] && pass "A's block $LBA now reads FREE in BG $BG's bitmap" || { fail "no Block Group holds block $LBA"; ct_exit; }
"$BGPOKE" "$BACK" "$BG" 1 sync-zg >/dev/null
free_total="$("$MAP" "$DEV" | awk '$1 == "bg" {split($5,a,"="); split(a[2],b,"/"); s += b[1]} END {print s+0}')"
[ "$free_total" = 1 ] && pass "the volume has exactly one free block: A's" ||
    { fail "setup: $free_total free blocks, the growth would not be steered onto A's"; ct_exit; }

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grew=0
touch "$MNT/B/grow" 2>/dev/null && grew=1
log "B's growth into A's block: $([ "$grew" = 1 ] && echo succeeded || echo refused)"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
listing="$(ls "$MNT/A" 2>&1 | tr '\n' ' ')"
if [ "$listing" = "f1 f2 f3 f4 f5 " ]; then
    pass "A still lists its five names"
else
    fail "A's names were destroyed by B's growth: ls A -> '$listing'"
fi
if [ "$grew" = 0 ]; then
    pass "the growth into a block a live directory lists was refused"
else
    fail "the growth into A's block succeeded"
fi
ct_umount "$MNT"

rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if ! grep -qE '^ERR.*(FREE|shared|cross|twice|claimed)' <<<"$out"; then
    pass "fsck: A's block is no longer free-but-referenced or shared"
else
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
fi

ct_exit
