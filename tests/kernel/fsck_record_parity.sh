#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports the inode records the kernel refuses or misreads
#
# Each case below is a record fsck called clean and the kernel does not
# accept: a type iget refuses, a live record with no extent header (the
# first map is -EIO), an extent of length 0 or ending past the largest
# file (seek/fiemap and the unwritten convert call the volume corrupt),
# and a depth-2 extent outside the range its index entry advertises --
# the lookup skips that leaf, the block reads as a hole and the next
# write allocates over it.
#
# One fault per case on a fresh copy of the same image, CRCs restamped.
#
# DISCRIMINATION: without the checks every case reads clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 recparity)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt recparity)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/data" bs=4096 count=4 status=none
: >"$MNT/empty"
python3 -I - "$MNT/deep" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
for i in range(300):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
DI="$(stat -c %i "$MNT/data")"; EI="$(stat -c %i "$MNT/empty")"; PI="$(stat -c %i "$MNT/deep")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"
grep -q depth=2 <<<"$("$POKE" "$IMG" extents "$PI" 2>&1)" || { fail "setup: 'deep' did not reach depth 2"; ct_exit; }
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the volume is not clean before any poke"; ct_exit; }
TPL="$IMG.tpl"; ct_track file "$TPL"
cp --sparse=always "$IMG" "$TPL"
pass "setup: a data file, an empty file and a depth-2 file; fsck clean"

case_() { # <label> <regex> <poke args...>
    local label="$1" re="$2" out
    shift 2
    dd if="$TPL" of="$IMG" bs=1M conv=notrunc,sparse status=none
    "$POKE" "$IMG" "$@" >/dev/null 2>&1 || { fail "$label: setup: the poke failed"; return; }
    blockdev --flushbufs "$DEV"
    out="$(ct_fsck "$DEV" 2>&1)" && { fail "$label: fsck called it clean"; return; }
    grep -qE "$re" <<<"$out" && pass "$label: $(grep -m1 -E "$re" <<<"$out")" ||
        fail "$label: fsck failed, but not on this: $(grep -m1 ERR <<<"$out")"
}

case_ "a FIFO" "mode 010644, a type" setmode "$DI" 010644
case_ "no extent header" "has no extent header" ehset "$EI" magic 0
case_ "length 0" "extent of length 0" extset "$DI" 0 len 0
case_ "past the largest file" "past the largest file" extset "$DI" 0 block 4294967294
case_ "an empty depth-2 root" "depth-2 extent tree with no entries" ehset "$PI" entries 0
# The empty root hides every block of the file: -r must not free them.
dd if="$TPL" of="$IMG" bs=1M conv=notrunc,sparse status=none
"$POKE" "$IMG" ehset "$PI" entries 0 >/dev/null 2>&1; blockdev --flushbufs "$DEV"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "nothing repaired" <<<"$OUT" && pass "an empty depth-2 root blocks -r (its blocks look leaked)" ||
    fail "fsck -r repaired around an empty depth-2 root: $(grep -E 'cleared|repaired' <<<"$OUT" | head -2)"
case_ "outside its index range" "outside the range .* its index advertises" idxrange "$PI" 0 100000 100001
ct_exit
