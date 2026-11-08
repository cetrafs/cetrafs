#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back leaf orphaned by eviction goes with its file's next fsync
#
# An inode evicted with tree blocks still held back (a boundary that
# failed) hands them to the mount's orphan list, which sync_fs and
# unmount write (cetrafs_deferred_evict()). When the file is opened and
# edited again, the edit found the block's bit set and its entry listed
# and left it where it was -- on the orphan list. The file's own
# boundaries walk only its own list, so fsync and close returned with
# the edit still in core, and a split's shrunk source leaf could miss
# the batch its destination went in (REVIEW-FIXES.md, from f3e3f17).
# The edit now moves the entry onto its inode's list.
#
# Staged on a journaled volume: a preallocated file with an external
# leaf; an O_DIRECT write edits the leaf (held back), and the close's
# flush writes nothing (tree_flush_skip_all -- a close whose flush FAILS
# pins the inode until a retry has flushed, so it cannot stage this), so
# an eviction orphans the leaf -- procfs deferred_orphaned says so. The file is reopened, the same leaf edited
# again, and fsync'd. The leaf on the device must then carry both edits.
#
# DISCRIMINATION: without the move the fsync writes nothing and the
# device's leaf still maps both blocks as preallocated (and
# deferred_adopted stays 0).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/tree_flush_skip_all ] || { skip "tree_flush_skip_all is missing"; ct_exit; }
LP="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 doa)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt doa)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set tree_flush_skip_all 0 # recorded before the helper below sets it
F="$MNT/img"

# dio_write <path> <block> <tag> [fsync|failclose]
dio_write() {
    python3 - "$@" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(sys.argv[3].encode() * (4096 // len(sys.argv[3])))
os.pwritev(fd, [buf], int(sys.argv[2]) * 4096)
mode = sys.argv[4] if len(sys.argv) > 4 else ""
if mode == "fsync":
    os.fsync(fd)
if mode == "failclose":
    with open("/sys/module/cetrafs/parameters/tree_flush_skip_all", "w") as k:
        k.write("1")
os.close(fd)
PY
}
python3 - "$F" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(4 << 20)) == 0
os.close(fd)
PY
# Eight written blocks, gaps between: past the four inline slots, so the
# map spills to an external leaf, and far from full -- every conversion
# below stays in that one leaf, where `show` can see it.
for i in $(seq 0 6); do dio_write "$F" $((i * 4)) "$(printf 'B%07d' $((i * 4)))"; done
dio_write "$F" 28 B0000028 fsync
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }
INO="$(stat -c %i "$F")"
L="$("$LP" "$IMG" leaf "$INO" 2>/dev/null || true)"
[ -n "$L" ] && [ "$L" -gt 0 ] 2>/dev/null || { fail "setup: no external leaf"; ct_exit; }
written() { "$LP" "$IMG" show "$INO" | grep -q "^ent [0-9]* block=$1 .* uninit=0$"; }

# 1. An edit held back, a close whose boundary fails, an eviction.
O0="$(info deferred_orphaned)"; A0="$(info deferred_adopted)"
dio_write "$F" 120 FIRST001 failclose
# The close left the inode dirty, and reclaim skips a dirty inode:
# syncfs cleans it (its tree flush is skipped too), then it can go.
sync -f "$F"
echo 2 >/proc/sys/vm/drop_caches
ct_param_set tree_flush_skip_all 0
O1="$(info deferred_orphaned)"
[ "$O1" -gt "$O0" ] || { fail "setup: the eviction orphaned nothing (deferred_orphaned $O0 -> $O1)"; ct_exit; }
written 120 && { fail "setup: the first edit reached the device -- it was not held back"; ct_exit; }
pass "setup: the inode left the cache with its leaf held back ($((O1 - O0)) block(s) orphaned)"

# 2. Reopen, edit the same leaf, fsync.
dio_write "$F" 200 SECOND01 fsync
A1="$(info deferred_adopted)"
[ "$A1" -gt "$A0" ] && pass "the edit brought the orphan back to its inode ($((A1 - A0)))" ||
    fail "the edit left the orphan where it was (deferred_adopted $A0 -> $A1)"
written 200 && pass "the reopened file's fsync wrote the leaf it edited" ||
    fail "fsync returned with the edit still in core: the device's leaf maps block 200 as preallocated"
written 120 && pass "...with the edit held back before the eviction" ||
    fail "the edit made before the eviction is still not on the device after the fsync"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
blk() { dd if="$F" bs=4096 skip="$1" count=1 status=none | head -c 8; }
[ "$(blk 120)" = FIRST001 ] && [ "$(blk 200)" = SECOND01 ] && pass "both blocks read back after a remount" ||
    fail "after a remount block 120 reads '$(blk 120)', block 200 '$(blk 200)'"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
