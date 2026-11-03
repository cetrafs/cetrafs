#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# preallocated blocks that land in a NEW extent leaf read as zeros, not as the old disk contents
#
# cetrafs_tree_append() grows the tree when the last leaf is full: a new
# leaf holding the one extent being added. It built that extent with
# cetrafs_extent_pack_len(1, 0) -- initialised -- whatever the caller
# asked for. fallocate(2) asks for UNINITIALISED, so the first block of
# every new leaf a preallocation reached was recorded as holding data,
# and reading it returned whatever the block held before: a deleted
# file's contents, on a shared datastore possibly another VM's.
#
# The suite fills the volume with a marker, deletes it, then
# preallocates single blocks with gaps between them (so none merge) past
# the first leaf's capacity, reaching both new-leaf sites (depth 1 ->
# 2, and a new leaf under the depth-2 interior). Every preallocated
# block must read back as zeros.
#
# DISCRIMINATION: on the unfixed code the first block of each new leaf
# reads back as the marker.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAF=254 # CETRAFS_EXT_BLOCK_MAX_LEAVES (12-byte header, 16-byte extents, block tail)
NB=$((2 * LEAF + 60)) # past two full leaves

DEV="$(ct_dev 560 fnleaf)"
MNT="$(ct_mnt fnleaf)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

python3 -c 'import sys; open(sys.argv[1],"wb").write(b"\xa5" * (300 << 20))' "$MNT/marker" 2>/dev/null || true
sync
rm -f "$MNT/marker"
sync
ct_umount "$MNT" # let the frees settle before anything is allocated again
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

OUT="$(python3 - "$MNT/f" "$NB" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
path, nb = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
for i in range(nb):  # every other block: separate extents, none merge
    if libc.fallocate(fd, 0, ctypes.c_long(2 * i * 4096), ctypes.c_long(4096)) != 0:
        print("FALLOCATE_FAILED", i, os.strerror(ctypes.get_errno())); sys.stdout.flush(); os._exit(1)
os.close(fd)
print("ok")
PY
)"
[ "$OUT" = ok ] && pass "setup: $NB separate one-block preallocations" || { fail "setup: $OUT"; ct_exit; }
sync
echo 3 >/proc/sys/vm/drop_caches

blocks="$(stat -c %b "$MNT/f")"
[ "$blocks" -ge $((NB * 8)) ] && pass "setup: the preallocation is on the file ($blocks sectors)" ||
    { fail "setup: only $blocks sectors allocated"; ct_exit; }

read -r bad marker <<<"$(python3 - "$MNT/f" "$NB" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = mk = 0
z = bytes(4096)
for i in range(int(sys.argv[2])):
    d = os.pread(fd, 4096, 2 * i * 4096)
    if d != z:
        bad += 1
        if d == b"\xa5" * 4096: mk += 1
print(bad, mk)
PY
)"
[ "$bad" = 0 ] && pass "every preallocated block reads as zeros" ||
    fail "$bad preallocated block(s) read non-zero ($marker of them the deleted file's contents)"
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
