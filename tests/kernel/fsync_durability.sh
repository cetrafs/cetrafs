#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsync() must make the metadata that FINDS the data durable too
#
# .fsync was simple_fsync(): flush the data pages, and write the inode
# record if it is dirty. That is everything a simple filesystem has --
# but once a file spills past four extents its extent list lives in an
# external LEAF BLOCK, and a contiguous append only extends the last
# entry's length in place. cetrafs_get_block() deliberately does not
# sync that (it is the hot path for a growing file); the flush happened
# at the last writer's close. The leaf is a raw metadata block, not part
# of the inode's page-cache mapping, so nothing that flushes the file's
# DATA touches it.
#
# So fsync() returned success with the extents describing the write
# still only in memory. Measured before the fix: 401 blocks written and
# fsync'd, with the on-disk leaf mapping 151 of them -- 1 MB of
# acknowledged data present on the device but unreachable. For a
# datastore of VM images that is the guest's flush barrier being a lie.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# This suite needs FRAGMENTED files: an external leaf, a depth-1 tree, an
# auto-defrag trigger. Speculative run allocation makes a sequential write
# land contiguously and merge into one extent, so the fragmentation its
# setup relies on never happens and the suite would test nothing (several
# assertions below check exactly that precondition, which is how this was
# caught). Turn runs off so allocation goes back one block at a time.
ct_param_set alloc_run_blocks 0
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fsync)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsync)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "a depth-1 file's extents are durable at fsync, not only at close"
OUT="$(python3 - "$MNT" "$IMG" "$POKE" <<'PY'
import os, sys, subprocess
mnt, img, poke = sys.argv[1], sys.argv[2], sys.argv[3]

def leaf(ino):
    return subprocess.run([poke, img, "leaf", str(ino)], capture_output=True, text=True).stdout.strip()

a = os.open(mnt + "/a", os.O_RDWR | os.O_CREAT, 0o644)
b = os.open(mnt + "/b", os.O_RDWR | os.O_CREAT, 0o644)
# Interleaved, so a's blocks fragment into separate extents and the
# extent array spills into an external leaf.
for i in range(150):
    os.pwrite(a, b"A" * 4096, i * 4096)
    os.pwrite(b, b"B" * 4096, i * 4096)
ino = os.fstat(a).st_ino
os.close(b)
os.fsync(a)
print("spilled:" + leaf(ino))
# Now append CONTIGUOUSLY: nothing else is allocating, so each block
# merges into the last extent by extending its length -- the case
# get_block defers.
for i in range(150, 400):
    os.pwrite(a, b"A" * 4096, i * 4096)
os.fsync(a)
print("fsynced:" + leaf(ino))
print("blocks:%d" % (os.fstat(a).st_blocks // 8))
os.close(a)
print("closed:" + leaf(ino))
PY
)"
echo "$OUT" | sed 's/^/    /'
SPILLED="$(echo "$OUT" | sed -n 's/^spilled://p')"
FSYNCED="$(echo "$OUT" | sed -n 's/^fsynced://p')"
CLOSED="$(echo "$OUT" | sed -n 's/^closed://p')"
FILE_BLOCKS="$(echo "$OUT" | sed -n 's/^blocks://p')"
LEAF_AT_FSYNC="$(echo "$FSYNCED" | sed -n 's/.*leaf_blocks=//p')"
LEAF_AT_CLOSE="$(echo "$CLOSED" | sed -n 's/.*leaf_blocks=//p')"

case "$SPILLED" in
depth=1*) pass "the file really did spill into an external extent leaf" ;;
*) fail "the file never reached depth 1, so this suite is not testing the leaf: $SPILLED" ;;
esac
# The file has one extra block (its first, before the run), so compare
# against what close eventually makes durable rather than a magic number.
[ -n "$LEAF_AT_FSYNC" ] && [ "$LEAF_AT_FSYNC" = "$LEAF_AT_CLOSE" ] &&
    pass "fsync made the whole extent list durable ($LEAF_AT_FSYNC blocks mapped, same as after close)" ||
    fail "fsync left the leaf mapping $LEAF_AT_FSYNC blocks; close later made it $LEAF_AT_CLOSE -- acknowledged writes were not durable"
[ "$LEAF_AT_FSYNC" -ge "$((FILE_BLOCKS - 2))" ] &&
    pass "the durable extent list covers the file's $FILE_BLOCKS blocks" ||
    fail "the file has $FILE_BLOCKS blocks but only $LEAF_AT_FSYNC are mapped on disk"

log "a depth-0 file's record is durable at fsync too"
OUT2="$(python3 - "$MNT" "$IMG" "$POKE" <<'PY'
import os, sys, subprocess
mnt, img, poke = sys.argv[1], sys.argv[2], sys.argv[3]
f = os.open(mnt + "/small", os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(f, b"S" * 4096 * 64, 0)
ino = os.fstat(f).st_ino
os.fsync(f)
print(subprocess.run([poke, img, "extents", str(ino)], capture_output=True, text=True).stdout.strip())
os.close(f)
PY
)"
case "$OUT2" in
*"blocks=512"*) pass "a depth-0 file's size and extents are on disk at fsync ($OUT2)" ;;
*) fail "after fsync the record reads '$OUT2', expected 512 blocks" ;;
esac

log "the data itself reads back correctly"
[ "$(stat -c '%s' "$MNT/a")" = "$((400 * 4096))" ] && pass "the file's size is what was written" ||
    fail "size is $(stat -c '%s' "$MNT/a")"
python3 -c "
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if d == b'A' * len(d) and len(d) == 400 * 4096 else 1)" "$MNT/a" &&
    pass "every byte of the fragmented file reads back as written" ||
    fail "the file's contents are wrong"

log "fsync on a directory still works"
mkdir "$MNT/d"
: >"$MNT/d/f"
python3 -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
os.fsync(fd)
os.close(fd)" "$MNT/d" && pass "fsync of a directory succeeds" || fail "fsync of a directory failed"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
