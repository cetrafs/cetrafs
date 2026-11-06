#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new directory block whose owner cannot be judged is kept, not zeroed; mkdir is guarded too
#
# A block the allocator hands to a directory is zeroed and stamped before
# it becomes reachable, behind a guard for the allocator being wrong: if
# the block's '.' names a live directory that still lists it, it is left
# alone and stays allocated (dirent_init_live_block.sh). Two holes
# (audit 2026-11-06 L1):
#  - the guard answered "not owned" when the owner's record could not be
#    read, and the block was zeroed; and when it did answer "cannot
#    tell", the growth path freed the block it had just allocated;
#  - mkdir zeroed its first block with no guard at all.
#
# Staged as dirent_init_live_block.sh: directory A's first block reads
# FREE in the bitmap on an otherwise full volume, so the next directory
# block allocated is A's.
#  (1) mkdir is handed it: mkdir must fail and A keep its names.
#  (2) A's record is made unreadable (bad checksum), and B grows into the
#      block: the growth must fail, the block's bytes must be unchanged,
#      and its bitmap bit must stay set.
#
# DISCRIMINATION: unguarded, (1)'s mkdir zeroes A's block; failing open,
# (2)'s growth zeroes it, or frees it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

MAP="$(ct_helper bg_map)"
BGPOKE="$(ct_helper bg_poke)"
IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper csum_poke)"
MNT="$(ct_mnt direntfc)"

# The block-in-bitmap locator: prints "<bg> <byte offset> <bit>".
locate() { # <backing> <lba>
    python3 - "$1" "$2" "$("$MAP" "$DEV")" <<'PY'
import os, struct, sys
back, lba = sys.argv[1], int(sys.argv[2])
fd = os.open(back, os.O_RDONLY)
for line in sys.argv[3].splitlines():
    f = line.split()
    if f[0] != "bg":
        continue
    start = int(f[3].split("=")[1])
    length, off_bmap, off_data = struct.unpack_from("<QII", os.pread(fd, 24, start * 4096), 8)
    if start + off_data <= lba < start + length:
        bit = lba - start - off_data
        print(f[1], (start + off_bmap) * 4096 + bit // 8, bit % 8)
        break
PY
}
bit_of() { python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); print((os.pread(fd,1,int(sys.argv[2]))[0]>>int(sys.argv[3]))&1)' "$@"; }
clear_bit() { python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDWR); o=int(sys.argv[2]); v=os.pread(fd,1,o)[0]; os.pwrite(fd,bytes([v&~(1<<int(sys.argv[3]))]),o); os.fsync(fd)' "$@"; }
blk_sum() { dd if="$1" bs=4096 skip="$2" count=1 status=none | md5sum | cut -d' ' -f1; }

# A with five names, B exactly one full block, the volume full, A's
# first block FREE in the bitmap with the counts agreeing.
stage() { # <tag>
    DEV="$(ct_dev 560 "direntfc$1")"
    BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/A" "$MNT/B"
    for i in 1 2 3 4 5; do touch "$MNT/A/f$i"; done
    for i in $(seq 1 13); do touch "$MNT/B/b$i"; done
    INO_A="$(stat -c %i "$MNT/A")"
    local i=0
    while dd if=/dev/zero of="$MNT/fill$i" bs=1M count=64 status=none 2>/dev/null; do i=$((i + 1)); done
    sync
    ct_umount "$MNT"
    LBA="$("$IPOKE" "$BACK" extents "$INO_A" | awk '/^ext 0 /{split($4,a,"="); print a[2]}')"
    [ -n "$LBA" ] || { fail "setup $1: no first block for A"; ct_exit; }
    read -r BG BOFF BBIT <<<"$(locate "$BACK" "$LBA")"
    [ -n "${BG:-}" ] && [ "$(bit_of "$BACK" "$BOFF" "$BBIT")" = 1 ] || { fail "setup $1: A's block $LBA is not allocated in any BG"; ct_exit; }
    clear_bit "$BACK" "$BOFF" "$BBIT"
    "$BGPOKE" "$BACK" "$BG" 1 sync-zg >/dev/null
    local free_total
    free_total="$("$MAP" "$DEV" | awk '$1 == "bg" {split($5,a,"="); split(a[2],b,"/"); s += b[1]} END {print s+0}')"
    [ "$free_total" = 1 ] || { fail "setup $1: $free_total free blocks, want exactly A's"; ct_exit; }
    SUM0="$(blk_sum "$BACK" "$LBA")"
}

ct_param_set alloc_run_blocks 0 # no speculative runs: the fill must leave nothing free

# --- 1: mkdir handed a live directory's block
stage 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
RC=0; mkdir "$MNT/C" 2>/dev/null || RC=$?
dmesg_since "$MARK" | grep -q "block $LBA was allocated as free, but LIVE directory" ||
    { [ "$RC" = 0 ] || fail "setup 1: mkdir failed without being handed A's block"; }
ct_umount "$MNT"
[ "$RC" != 0 ] && pass "1: mkdir handed a block a live directory lists was refused" ||
    fail "1: mkdir succeeded into a block a live directory lists"
[ "$(blk_sum "$BACK" "$LBA")" = "$SUM0" ] && pass "1: A's block is untouched" || fail "1: mkdir overwrote A's block"
ct_mount "$DEV" "$MNT"
L="$(ls "$MNT/A" 2>&1 | tr '\n' ' ')"
[ "$L" = "f1 f2 f3 f4 f5 " ] && pass "1: A still lists its five names" || fail "1: ls A -> '$L'"
ct_umount "$MNT"

# --- 2: a growth handed a block whose owner's record cannot be read
stage 2
"$CPOKE" "$BACK" inode "$INO_A" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
RC=0; touch "$MNT/B/grow" 2>/dev/null || RC=$?
ct_umount "$MNT"
dmesg_since "$MARK" | grep -qE "block $LBA (names directory|was allocated)" || [ "$RC" = 0 ] ||
    log "note: the growth failed without a guard message"
[ "$RC" != 0 ] && pass "2: the growth into a block whose owner cannot be read was refused" ||
    fail "2: the growth into a block whose owner cannot be read succeeded"
[ "$(blk_sum "$BACK" "$LBA")" = "$SUM0" ] && pass "2: the block's bytes are unchanged" ||
    fail "2: the block was zeroed although its owner could not be judged"
[ "$(bit_of "$BACK" "$BOFF" "$BBIT")" = 1 ] && pass "2: the block stays allocated" ||
    fail "2: the block was freed although its owner could not be judged"
ct_exit
