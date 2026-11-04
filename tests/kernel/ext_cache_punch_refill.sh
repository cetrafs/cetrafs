#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the remembered extent never answers for a map that changed and came back
#
# get_block remembers the last extent it resolved, keyed on the record
# it came from. The key was (depth, root entries, blocks): for a spilled
# tree the root entry count is the number of index entries and rarely
# moves, so the key was in effect the block count -- and a punch of k
# blocks followed by an allocation of k brings it back (ABA). An entry
# stored before the punch published survived it; once an O_DIRECT
# refill brought the block count back, lookups in the punched range
# returned the FREED
# blocks: reads saw another file's (here: the old) data, and writes
# went into blocks the allocator may give to another file.
#
# Not reachable on this code through the drops: every rewrite of the
# map (cetrafs_tree_build()) drops the entry again inside the exclusion
# that keeps walkers out until the publish. So the test takes the drops
# away (ext_cache_skip_drop) and leaves the KEY as the only guard -- the
# property the cache's own comment claimed for it.
#
# Staged on a depth-1 tree of 16 extents of 64 blocks: an O_DIRECT read
# of 8 blocks in extent 5 (the walk is remembered), a punch of them, an
# O_DIRECT refill with a new pattern (the block count comes back), an
# O_DIRECT read back.
#
# DISCRIMINATION: with the count-only key the read returns the old
# pattern from the freed blocks (measured).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/ext_cache_skip_drop ] || { skip "ext_cache_skip_drop is missing"; ct_exit; }

IMG="$(ct_image 560 extaba)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt extaba)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
f = os.open(d + "/vm.img", os.O_WRONLY | os.O_CREAT, 0o644)
g = os.open(d + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
for e in range(16):
    os.pwrite(f, b"A" * (64 * 4096), e * 64 * 4096); os.fsync(f)
    os.pwrite(g, b"s" * 4096, e * 4096); os.fsync(g)
os.close(f); os.close(g)
PY
sync
EXT="$(filefrag "$MNT/vm.img" 2>/dev/null | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p')"
[ "${EXT:-0}" -ge 8 ] || { fail "setup: only ${EXT:-?} extents -- the tree did not spill"; ct_exit; }
pass "setup: a spilled tree of $EXT extents"

ct_param_set ext_cache_skip_drop 1
RES="$(python3 - "$MNT/vm.img" <<'PY'
import ctypes, mmap, os, sys
p = sys.argv[1]
B = 4096
FALLOC_FL_KEEP_SIZE, FALLOC_FL_PUNCH_HOLE = 1, 2
e0 = 5 * 64
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(p, os.O_RDWR)                       # held: the cache is consulted for a local writer
dfd = os.open(p, os.O_RDWR | os.O_DIRECT)
rb = mmap.mmap(-1, 8 * B)
os.preadv(dfd, [rb], (e0 + 8) * B)               # the walk is remembered
if libc.fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                  ctypes.c_long((e0 + 8) * B), ctypes.c_long(8 * B)) != 0:
    print("punch-failed", ctypes.get_errno()); sys.exit(0)
buf = mmap.mmap(-1, 8 * B); buf.write(b"Z" * (8 * B))
os.pwritev(dfd, [buf], (e0 + 8) * B)             # refill: the block count comes back
rb = mmap.mmap(-1, 8 * B)
os.preadv(dfd, [rb], (e0 + 8) * B)
got = bytes(rb[:])
print("ok" if got == b"Z" * (8 * B) else "stale:%r" % sorted(set(got)))
os.close(dfd); os.close(fd)
PY
)"
ct_param_set ext_cache_skip_drop 0
case "$RES" in
ok) pass "the refilled range reads back what was written" ;;
punch-failed*) fail "setup: the punch failed ($RES)" ;;
*) fail "the refilled range read back $RES -- a lookup answered from the pre-punch mapping (freed blocks)" ;;
esac
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
