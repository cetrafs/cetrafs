#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a buffered write's blocks read as data on this node before they are marked written
#
# A buffered write into preallocated space, or a hole, leaves its blocks
# PREALLOCATED in the tree until the next fsync/close/sync marks them
# written -- after the data is on the device (audit R12; the crash side
# is tests/crash/buffered_extent_order.sh). Meanwhile this node must
# read them as the data they hold, even once the page cache has let the
# pages go: a read, SEEK_DATA/SEEK_HOLE, fiemap, a partial overwrite
# that reads the rest of the block back, and a store through a mapping.
# And the set that says so must forget a block the moment it is punched,
# or a block preallocated at that offset afterwards would read as data
# -- whatever its previous owner left there.
#
# The pages are written back (sync_file_range) and dropped
# (POSIX_FADV_DONTNEED) without an fsync, which would convert.
#
# DISCRIMINATION: without the pending lookup in get_block the evicted
# block reads as zeros; without the punch's clear, the re-preallocated
# block reads the punched data.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 bpend)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bpend)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
# Poison the free space (as fallocate_allocate.sh does): a block that
# reads as data without having been written then reads 0xAB, not zeros.
FREE_MB=$(( $(stat -f -c %f "$MNT") * 4096 / 1048576 ))
POISON_MB=$(( FREE_MB - 16 ))
[ "$POISON_MB" -ge 64 ] || { fail "setup: volume too small to poison (${FREE_MB} MiB free)"; ct_exit; }
"$(ct_helper poison_fill)" "$MNT/poison" "$POISON_MB" || { fail "setup: could not poison the volume"; ct_exit; }
sync
rm -f "$MNT/poison"
sync

OUT="$(ct_tmp bpend-out)"
python3 - "$MNT/f" >"$OUT" 2>&1 <<'PY' || true
import ctypes, mmap, os, sys
libc = ctypes.CDLL(None, use_errno=True)
BS = 4096
p = sys.argv[1]

def evict(fd):
    # write back WITHOUT fsync (which would convert), then let the pages go
    if libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(0), 7) != 0:
        print("SETUP sync_file_range failed", ctypes.get_errno()); sys.exit(0)
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)

def rd(fd, blk):
    return os.pread(fd, BS, blk * BS)

def seek(fd, off, whence):
    try:
        return os.lseek(fd, off, whence)
    except OSError as e:
        return "errno %d" % e.errno

def say(tag, ok, detail=""):
    print("%s %s %s" % ("OK" if ok else "BAD", tag, detail))

fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
os.posix_fallocate(fd, 0, 16 * BS)       # blocks 0..15 preallocated
os.ftruncate(fd, 64 * BS)                # 16..63 a hole inside i_size
os.fsync(fd)

os.pwrite(fd, b"P" * BS, 5 * BS)         # into the preallocation
os.pwrite(fd, b"H" * BS, 40 * BS)        # into the hole
evict(fd)
say("read-prealloc", rd(fd, 5) == b"P" * BS, rd(fd, 5)[:8])
say("read-hole", rd(fd, 40) == b"H" * BS, rd(fd, 40)[:8])
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)  # SEEK must find them by the set, not the cache
# SEEK before any read of an untouched block: a cached page over a
# preallocated block counts as data (seek_hole_data.sh), zeros included.
say("seek-data", seek(fd, 0, os.SEEK_DATA) == 5 * BS, seek(fd, 0, os.SEEK_DATA))
say("seek-hole", seek(fd, 5 * BS, os.SEEK_HOLE) == 6 * BS, seek(fd, 5 * BS, os.SEEK_HOLE))
say("seek-data-hole", seek(fd, 6 * BS, os.SEEK_DATA) == 40 * BS, seek(fd, 6 * BS, os.SEEK_DATA))
say("unwritten-zero", rd(fd, 7) == bytes(BS))

# a partial overwrite reads the rest of the block back from the device
os.pwrite(fd, b"Q" * 100, 5 * BS)
evict(fd)
say("partial", rd(fd, 5) == b"Q" * 100 + b"P" * (BS - 100), rd(fd, 5)[:8] + rd(fd, 5)[100:108])

# punch the pending block, preallocate the offset again: zeros, never the punched bytes
FALLOC_FL_KEEP_SIZE, FALLOC_FL_PUNCH_HOLE = 1, 2
if libc.fallocate(fd, FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE, ctypes.c_longlong(40 * BS), ctypes.c_longlong(BS)) != 0:
    print("SETUP punch failed", ctypes.get_errno()); sys.exit(0)
if libc.fallocate(fd, FALLOC_FL_KEEP_SIZE, ctypes.c_longlong(40 * BS), ctypes.c_longlong(BS)) != 0:
    print("SETUP re-allocate failed", ctypes.get_errno()); sys.exit(0)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
say("punch-forgets", rd(fd, 40) == bytes(BS), rd(fd, 40)[:8])
# the same through truncate: a pending block past the new end, cut, re-preallocated
os.pwrite(fd, b"T" * BS, 50 * BS)
evict(fd)
os.ftruncate(fd, 50 * BS)
os.ftruncate(fd, 64 * BS)
if libc.fallocate(fd, FALLOC_FL_KEEP_SIZE, ctypes.c_longlong(50 * BS), ctypes.c_longlong(BS)) != 0:
    print("SETUP re-allocate after truncate failed", ctypes.get_errno()); sys.exit(0)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
say("truncate-forgets", rd(fd, 50) == bytes(BS), rd(fd, 50)[:8])
# a store through a mapping -- last: Python's mmap holds a dup of the fd,
# and closing it is a close(2) (->flush converts the whole set)
m = mmap.mmap(fd, 16 * BS)
m[9 * BS:10 * BS] = b"M" * BS
m.close()
evict(fd)
say("mmap", rd(fd, 9) == b"M" * BS, rd(fd, 9)[:8])

os.close(fd)

# closed: converted, and still the data
fd = os.open(p, os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
say("after-close", rd(fd, 5) == b"Q" * 100 + b"P" * (BS - 100) and rd(fd, 9) == b"M" * BS)
os.close(fd)
print("DONE")
PY
log "$(tr '\n' ';' <"$OUT")"
grep -q '^SETUP' "$OUT" && { fail "setup: $(grep '^SETUP' "$OUT")"; ct_exit; }
grep -q '^DONE' "$OUT" || { fail "the workload did not finish: $(tail -3 "$OUT")"; ct_exit; }
while read -r v tag detail; do
    [ "$v" = OK ] && pass "$tag" || fail "$tag: $detail"
done < <(grep -E '^(OK|BAD) ' "$OUT")

if command -v filefrag >/dev/null; then
    # Fresh pending blocks, asked about while the file is still open (a
    # close converts them): fiemap must not call them unwritten.
    FF="$(python3 - "$MNT/g" <<'PY'
import ctypes, os, subprocess, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
os.posix_fallocate(fd, 0, 8 * 4096)
os.fsync(fd)
os.pwrite(fd, b"F" * 4096 * 8, 0)
libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(0), 7)
print(subprocess.run(["filefrag", "-v", sys.argv[1]], capture_output=True, text=True).stdout)
os.close(fd)
PY
)"
    grep -q unwritten <<<"$FF" && fail "fiemap reports written-but-unconverted data as unwritten: $FF" ||
        pass "fiemap reports the pending blocks as data"
fi

ct_umount "$MNT"
OUT2="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT2" && fail "fsck: $(grep '^ERR' <<<"$OUT2" | head -3)" || pass "fsck clean"
ct_exit
