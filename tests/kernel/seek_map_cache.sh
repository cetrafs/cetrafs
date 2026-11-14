#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fiemap and SEEK reuse a depth-2 file's sorted map only while its tree is unchanged
#
# Sorting a fragmented image's extents per call cost ~47 ms of CPU under
# the inode lock: filefrag of one 16 GiB preallocated image on an FC
# array took 42 s, and qemu's block status is one lseek pair per
# request. The sorted map is now kept on the inode while the file is open
# and reused while the tree's identity -- every tree block's address,
# eh_generation and tail CRC (cetrafs_tree_identity()) -- is unchanged.
#
# The danger is a STALE map: SEEK_DATA calling new data a hole, and a
# sparse copy skipping it. So: a fragmented preallocated file (depth 2)
# is held open and seeked, which caches the map; an O_DIRECT write
# through a second fd held open alongside then converts a preallocated
# block in place -- a leaf edit and nothing else, no page cache, no
# close (a close drops the map) -- and SEEK_DATA must see it.
#
#  1. many FIEMAP calls (filefrag) build the map once and reuse it
#  2. after the in-place convert, SEEK_DATA through the held fd finds
#     the new data (the key moved, the map was rebuilt)
#  3. fiemap through the held fd reports the block written, not unwritten
#
# DISCRIMINATION: smap_trust_stale hands back the cached map whatever
# its key; 2 and 3 must then fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "filefrag is missing"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/smap_trust_stale ] || { skip "smap_trust_stale is missing"; ct_exit; }

IMG="$(ct_image 560 smc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt smc-mnt)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set smap_trust_stale 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

N=8000 # preallocated blocks; every other one written -> ~N extents, depth 2
fallocate -l $((N * 4096)) "$MNT/img"
python3 - "$MNT/img" "$N" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(b"d" * 4096)
for i in range(0, int(sys.argv[2]) - 2, 2):
    os.pwrite(fd, buf, i * 4096)
os.fsync(fd)
os.close(fd)
PY
EXT="$(python3 - "$MNT/img" <<'PY'
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, 0, 0))
fcntl.ioctl(fd, 0xC020660B, buf)
print(struct.unpack("QQIIII", bytes(buf))[3])
PY
)"
[ "$EXT" -ge 4000 ] || { fail "setup: $EXT extents, wanted a depth-2 tree (>= 4000)"; ct_umount "$MNT"; ct_exit; }
pass "setup: $EXT extents in a preallocated file"

# 1. filefrag's many FIEMAP calls build the map once.
b0="$(info smap_builds)"; h0="$(info smap_hits)"
filefrag "$MNT/img" >/dev/null
B=$(($(info smap_builds) - b0)); H=$(($(info smap_hits) - h0))
[ "$B" -eq 1 ] && [ "$H" -ge 1 ] && pass "1: filefrag built the map once and reused it $H times" ||
    fail "1: filefrag built the map $B times and reused it $H times"

# <trust_stale 0|1> -> "<seek_data answer> <fiemap flags of the block>"
# for the preallocated block HOLE, through one fd held across a convert.
HOLE=$(((N - 1) * 4096)) # never written: preallocated
probe() {
    ct_param_set smap_trust_stale "$1"
    python3 - "$MNT/img" "$HOLE" <<'PY'
import fcntl, mmap, os, struct, sys
path, hole = sys.argv[1], int(sys.argv[2])
def flags_at(fd, off):
    hdr = struct.pack("QQIIII", off, 4096, 0, 0, 1, 0)
    buf = bytearray(hdr + bytes(56))
    fcntl.ioctl(fd, 0xC020660B, buf)
    if struct.unpack("QQIIII", bytes(buf[:32]))[3] == 0:
        return "none"
    return "unwritten" if struct.unpack_from("QQQQQII", buf, 32)[5] & 0x800 else "written"
# Both fds open before the map is cached and held to the end: a close
# drops the map (cetrafs_release()), and the key must be what catches
# the convert, not that.
w = os.open(path, os.O_WRONLY | os.O_DIRECT)
r = os.open(path, os.O_RDONLY)
try:
    before = os.lseek(r, hole, os.SEEK_DATA)
except OSError:
    before = "ENXIO"
flags_at(r, hole)
buf = mmap.mmap(-1, 4096)
buf.write(b"n" * 4096)
os.pwrite(w, buf, hole)
os.fsync(w)
try:
    after = os.lseek(r, hole, os.SEEK_DATA)
except OSError:
    after = "ENXIO"
print(before, after, flags_at(r, hole))
os.close(r)
os.close(w)
PY
    ct_param_set smap_trust_stale 0
}

read -r BEFORE AFTER FLAGS <<<"$(probe 0)"
[ "$BEFORE" = ENXIO ] || fail "setup: SEEK_DATA at the preallocated tail block returned $BEFORE, not ENXIO (a hole)"
[ "$AFTER" = "$HOLE" ] && pass "2: after the in-place convert SEEK_DATA through the held fd finds the new data at $HOLE" ||
    fail "2: SEEK_DATA through the held fd returned $AFTER, not $HOLE -- a stale map called new data a hole"
[ "$FLAGS" = written ] && pass "3: fiemap through the held fd reports the block written" ||
    fail "3: fiemap through the held fd reports the block $FLAGS"

# Control: the same sequence with the key ignored must go wrong. A fresh
# preallocated tail block, since the first one is data now.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
fallocate -o $((N * 4096)) -l 4096 "$MNT/img"
HOLE=$((N * 4096))
read -r BEFORE AFTER FLAGS <<<"$(probe 1)"
[ "$BEFORE" = ENXIO ] || fail "control setup: SEEK_DATA at the new preallocated block returned $BEFORE, not ENXIO"
[ "$AFTER" != "$HOLE" ] && [ "$FLAGS" != written ] &&
    pass "control: with the key ignored the held fd keeps the stale map (SEEK_DATA $AFTER, fiemap $FLAGS)" ||
    fail "control: with the key ignored the held fd still saw the convert (SEEK_DATA $AFTER, fiemap $FLAGS) -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
