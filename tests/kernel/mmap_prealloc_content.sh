#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a MAP_SHARED store into a preallocated range is what the file reads back as
#
# mmap_vs_write_alloc and mmap_vs_odirect_alloc check the fault path as an
# allocator. Nothing checked the CONTENT of a mapping over a preallocated
# (fallocate'd) range: a store lands in a block the tree still calls
# preallocated, reads of that range come back as zeros, and nothing but the
# data notices.
#
# Staged: fallocate 64 KiB, store a distinct byte into each page through a
# MAP_SHARED mapping, msync, unmount, remount (so no page cache answers),
# and read the file back. Every page must hold its store. Then fsck must
# be clean. A second run of the same shape does the same stores into a
# second preallocated file with buf_convert_skip=1: the durability boundary
# flushes the stored blocks and drops them from the pending set without
# marking their extents written; the readback must then show the loss, so a
# pass here cannot come from the check being unable to see zeros.
#
# A store through a mapping is a buffered store to the file system: its
# block is converted at the next durability boundary, like write(2)'s.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/buf_convert_skip ] || { skip "buf_convert_skip is missing"; ct_exit; }

PAGES=16
IMG="$(ct_image 560 mmapprealloc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmapprealloc)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# store <path>: fallocate PAGES pages, then store page i's byte through a
# shared mapping and msync. Prints nothing; exits nonzero on a setup error.
store() {
    python3 - "$1" "$PAGES" <<'PY'
import ctypes, mmap, os, sys
path, pages = sys.argv[1], int(sys.argv[2])
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(pages * 4096)):
    sys.exit("fallocate: errno %d" % ctypes.get_errno())
mm = mmap.mmap(fd, pages * 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
for i in range(pages):
    mm[i * 4096:(i + 1) * 4096] = bytes([0x30 + i]) * 4096
mm.flush()
mm.close()
os.close(fd)
PY
}

# verify <path>: prints "ok" if every page holds its store, else the bad pages.
verify() {
    python3 - "$1" "$PAGES" <<'PY'
import sys
path, pages = sys.argv[1], int(sys.argv[2])
d = open(path, "rb").read()
bad = [i for i in range(pages) if d[i * 4096:(i + 1) * 4096] != bytes([0x30 + i]) * 4096]
print("ok" if len(d) == pages * 4096 and not bad else "bad pages %s (size %d)" % (bad, len(d)))
PY
}

store "$MNT/prealloc"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
R="$(verify "$MNT/prealloc")"
[ "$R" = ok ] && pass "a shared store into a preallocated range reads back after a remount" ||
    fail "the stored pages did not read back: $R"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')" ||
    pass "fsck is clean after the preallocated stores"

log "control: the same stores with the mapped block left preallocated"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set buf_convert_skip 1
store "$MNT/skipped"
sync
ct_param_set buf_convert_skip 0
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
R="$(verify "$MNT/skipped")"
[ "$R" != ok ] && pass "control: without the conversion the stores do not read back ($R)" ||
    fail "control: the stores read back even without the conversion -- the knob does not reach the mapped store"
ct_umount "$MNT"
ct_exit
