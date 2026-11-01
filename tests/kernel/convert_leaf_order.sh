#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a split that moves part of an extent to another leaf never leaves both leaves naming it on the device
#
# Splitting a preallocated extent in a FULL leaf shrinks it there and
# appends what it gave up -- the written block and the rest of the
# preallocation -- through the tree, into another leaf. For a regular
# file both leaves are edited in place and left dirty in the block
# device's cache until close/fsync, and the block device writes dirty
# buffers in whatever order it likes. If the destination leaf reaches
# the device and the source does not, the device's tree names the moved
# blocks TWICE: a delete then frees them twice, the second time from
# under whichever file was given them in between.
#
# The crash is reproduced without a rig, as in leaf_before_bitmap.sh: a
# copy of the backing file is the device as it stands; every block the
# kernel holds dirty is written into it EXCEPT one, for each dirty block
# in turn -- every order the flusher can leave behind -- and fsck judges
# each. The file stays open: close and fsync are durability boundaries.
#
# The source leaf now goes to the device before the split moves on
# (cetrafs_convert_source_durable()), so no order can leave it behind.
#
# DISCRIMINATION (measured on the unfixed code, 3 of 3 runs): leaving
# out the source leaf gives "referenced by more than one inode".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 cvorder)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt cvorder)"
SNAP="$(ct_tmp cvorder-snap)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
NID="$(sed -n 's/^this_node_id: *//p' "$PROC/info")"
lf() { sed -n 's/^convert_leaf_full: //p' "$PROC/info"; }

# Preallocated, then every 4th block written: each write splits a
# preallocated extent in the middle, leaving 3-block preallocated gaps,
# until the first leaf is full and the tree has grown a second one.
F="$MNT/img"
python3 - "$F" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(16 << 20)) == 0
for i in range(400):
    os.pwrite(fd, b"w" * 4096, i * 4 * 4096)
os.fsync(fd)
os.close(fd)
PY
sync

exec 7<>"$F"
LF0="$(lf)"
# Block 42: the middle of the preallocated gap 41..43, in the full first leaf.
python3 -c 'import os,sys; os.pwrite(int(sys.argv[1]), b"x" * 4096, 42 * 4096)' 7
[ "$(lf)" -gt "$LF0" ] && pass "setup: the write split an extent in a full leaf" ||
    { fail "setup: the write did not reach the full-leaf split"; exec 7>&-; ct_exit; }

DIRTY="$(python3 - "$DEV" "$BACK" <<'PY'
import sys
a, b = open(sys.argv[1], "rb"), open(sys.argv[2], "rb")
i, out = 0, []
while True:
    x, y = a.read(1 << 20), b.read(1 << 20)
    if not x:
        break
    for k in range(0, len(x), 4096):
        if x[k:k + 4096] != y[k:k + 4096]:
            out.append(i + k // 4096)
    i += len(x) // 4096
print(" ".join(map(str, out)))
PY
)"
n=$(wc -w <<<"$DIRTY")
log "blocks dirty in cache, not on the device: $DIRTY"
for blk in $DIRTY; do # what each one is: extent header, cached vs device
    log "  $blk: $(python3 - "$DEV" "$BACK" "$blk" <<'PY2'
import struct, sys
def hdr(p):
    with open(p, "rb") as f:
        f.seek(int(sys.argv[3]) * 4096)
        m, e, mx, d = struct.unpack("<HHHH", f.read(8))
    return "magic=%#x entries=%d depth=%d" % (m, e, d)
print("cached", hdr(sys.argv[1]), "| device", hdr(sys.argv[2]))
PY2
)"
done
# What the split moved must still be only in cache, or no write order is
# left for the snapshots to try: a leaf that GAINED entries is dirty.
GREW="$(python3 - "$DEV" "$BACK" $DIRTY <<'PY2'
import struct, sys
def hdr(p, b):
    with open(p, "rb") as f:
        f.seek(b * 4096)
        return struct.unpack("<HHHH", f.read(8))
n = 0
for b in map(int, sys.argv[3:]):
    c, d = hdr(sys.argv[1], b), hdr(sys.argv[2], b)
    if c[0] == 0xC3E7 and c[3] == 0 and c[1] > d[1]:
        n += 1
print(n)
PY2
)"
[ "$GREW" -ge 1 ] && pass "setup: the leaf that received the moved blocks is only in cache ($n dirty block(s))" ||
    { fail "setup: no leaf that gained entries is dirty -- nothing to order"; exec 7>&-; ct_exit; }

bad=0
for skip in $DIRTY; do
    cp --sparse=always "$BACK" "$SNAP"
    for blk in $DIRTY; do
        [ "$blk" = "$skip" ] && continue
        dd if="$DEV" of="$SNAP" bs=4096 skip="$blk" seek="$blk" count=1 conv=notrunc status=none
    done
    "$NODE_POKE" "$SNAP" "$NID" 0 bb 0 >/dev/null # our row departed: no 35 s liveness watch
    sl="$(ct_loop "$SNAP")"
    out="$(ct_fsck "$sl" 2>&1)" || true
    losetup -d "$sl"
    rm -f "$SNAP"
    if grep -q 'more than one inode' <<<"$out"; then
        bad=$((bad + 1))
        log "all dirty blocks but $skip written: $(grep 'more than one inode' <<<"$out" | head -1)"
    fi
done
exec 7>&-
[ "$bad" = 0 ] && pass "no write order of the dirty blocks leaves a block named twice ($n orders)" ||
    fail "$bad of $n write orders leave the device's tree naming the moved blocks twice"

ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
