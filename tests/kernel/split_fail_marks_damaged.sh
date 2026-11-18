#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a leaf split that names its new leaf and then cannot shrink the old one marks the file damaged
#
# cetrafs_tree_split_leaf() names the new leaf in its interior first, then
# takes the moved entries out of the old leaf. When that second step is
# refused (a journal write refused before it lands restores the old
# leaf's image), the tree names the moved extents TWICE -- in core, and
# on the device once the held-back interior is written -- and a delete
# frees them twice: the second time from under whichever file was given
# them in between (format batch review MED-2).
#
# The file is now marked damaged: its writes are refused and its
# eviction frees nothing, until fsck settles it.
#
#   setup: a depth-2 fallocated file; one convert forced to split
#          (leaf_split_force) with its second step refused
#          (leaf_split_fail_shrink), and the kernel says so;
#   1. the next write to the file is refused (EUCLEAN);
#   2. so is its delete: nothing is freed through the doubled tree;
#   3. fsck reports the file's tree, for the repair.
#
# DISCRIMINATION: without the cetrafs_sb_corrupt_inode() call on that
# path, 1's write and 2's delete go through.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in leaf_split_force leaf_split_fail_shrink convert_unit_blocks; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
IBP="$(ct_helper inode_block_poke)"

IMG="$(ct_image 600 splitfail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt splitfail)"
ct_track mnt "$MNT"
ct_param_set convert_unit_blocks 1
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set leaf_split_off 0
ct_param_set leaf_split_force 0
ct_param_set leaf_split_fail_shrink 0
ct_mkfs "$DEV" -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# a fallocated 64 MiB file, block 0 then scattered blocks written: depth 2
python3 -I - "$MNT/f" 16384 1500 <<'PY'
import ctypes, os, random, sys
path, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if l.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
mv[:] = b"x" * 4096
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
r = random.Random(7)
for b in [0] + [r.randrange(64, nblk) for _ in range(nw)]:
    os.pwrite(fd, mv, b * 4096)
os.fsync(fd)
os.close(fd)
PY
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
DEPTH="$("$IBP" "$IMG" extents "$INO" 2>/dev/null | sed -n 's/^depth=\([0-9]*\).*/\1/p')"
[ "${DEPTH:-0}" -ge 2 ] || { fail "setup: the file's tree is depth ${DEPTH:-?}, not 2 -- no interior to split into"; ct_exit; }

ct_mount "$DEV" "$MNT"
MARK="$(dmesg_mark)"
ct_param_set leaf_split_force 1
ct_param_set leaf_split_fail_shrink 1
dd if=/dev/zero of="$MNT/f" bs=4096 count=1 seek=1 oflag=direct conv=notrunc status=none 2>/dev/null || true
ct_param_set leaf_split_force 0
ct_param_set leaf_split_fail_shrink 0
dmesg_since "$MARK" | grep -q "a leaf split named its new leaf but could not shrink the old one" ||
    { fail "setup: no split failed at its second step: $(dmesg_since "$MARK" | grep cetrafs | tail -2)"; ct_umount "$MNT"; ct_exit; }
pass "setup: a split named its new leaf and could not shrink the old one"

if dd if=/dev/zero of="$MNT/f" bs=4096 count=1 seek=200 oflag=direct conv=notrunc status=none 2>/dev/null; then
    fail "1: the next write to the file was accepted over a tree that names extents twice"
else
    pass "1: the next write to the file is refused"
fi
RMOUT="$(rm -f "$MNT/f" 2>&1)" || true
log "rm: ${RMOUT:-ok}"
sync
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "Structure needs cleaning" <<<"$RMOUT" &&
    pass "2: deleting it is refused too -- nothing is freed through the doubled tree" ||
    fail "2: the delete went through (${RMOUT:-no error}): the doubled tree's blocks were freed"
grep -qE "^ERR: inode $INO " <<<"$OUT" && pass "3: fsck reports the file's tree for repair" ||
    fail "3: fsck says nothing about inode $INO: $(grep -E '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')"
ct_exit
