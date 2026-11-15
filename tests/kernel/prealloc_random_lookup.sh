#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# random writes into a preallocated file keep a lookup to a few leaves
#
# A write into preallocated space converts an uninit extent, splitting it
# into up to three. Random 4 KiB writes fill the leaf holding the
# preallocation, and a convert that met a full leaf used to append the
# converted block and the preallocated tail to the tree's LAST leaf --
# every one of them, for the life of the file. Each leaf filled that way
# held blocks from all over the file, so its range spanned it, and a
# lookup read about half the leaves: ~94 us per lookup on a 4 GiB image,
# against ~1 us in a written one (prealloc writes ran at 1/26 of written
# ones on an FC array).
#
# A full leaf a convert meets is now split by logical range
# (cetrafs_tree_split_leaf()), so leaf ranges stay disjoint.
#
#  1. 12000 seeded random 4 KiB O_DIRECT writes into a 192 MiB fallocated
#     file; leaf_splits must move (the setup reached the split).
#  2. 200 scattered O_DIRECT reads after a cache drop: tree block reads
#     per lookup stay small.
#  3. Content: every written block holds its tag, every other block reads
#     zero -- after a remount -- and fsck is clean.
#
# DISCRIMINATION: leaf_split_off=1 restores the append; the same workload
# on a second file then reads many more tree blocks per lookup.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/leaf_split_off ] || { skip "leaf_split_off is missing"; ct_exit; }

IMG="$(ct_image 2200 prlookup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt prlookup)"
ct_track mnt "$MNT"
PD="$(basename "$DEV")"
ct_mkfs "$DEV" -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
ct_param_set leaf_split_off 0
c() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }

NBLK=49152 # 192 MiB
NW=12000

# <file> <seed>: fallocate, then the seeded random writes. Each written
# block holds its own block number and the seed.
fill() {
    python3 - "$1" "$2" "$NBLK" "$NW" <<'PY'
import os, sys, ctypes, random
path, seed, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if l.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
r = random.Random(seed)
for _ in range(nw):
    b = r.randrange(nblk)
    tag = (b"blk%08d-seed%04d\n" % (b, seed))
    mv[:] = (tag * (4096 // len(tag) + 1))[:4096]
    os.pwrite(fd, mv, b * 4096)
os.fsync(fd)
os.close(fd)
PY
}

# <file> <seed>: tree reads per lookup over 200 scattered written blocks,
# from a cold cache.
per_lookup() {
    local r0 r1
    sync
    echo 3 >/proc/sys/vm/drop_caches
    r0="$(c tree_reads)"
    python3 - "$1" "$2" "$NBLK" "$NW" <<'PY'
import os, sys, ctypes, random
path, seed, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r = random.Random(seed)
blocks = sorted(set(r.randrange(nblk) for _ in range(nw)))
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
step = max(1, len(blocks) // 200)
for b in blocks[::step][:200]:
    os.preadv(fd, [mv], b * 4096)
os.close(fd)
PY
    r1="$(c tree_reads)"
    echo $(((r1 - r0) / 200))
}

log "1: random writes into a preallocated file"
S0="$(c leaf_splits)"
fill "$MNT/main" 1 || { skip "fallocate unsupported here"; ct_umount "$MNT"; ct_exit; }
S1="$(c leaf_splits)"
TB="$(c tree_blocks)"
[ "$((S1 - S0))" -gt 0 ] && pass "1: setup: $((S1 - S0)) full leaves were split ($TB tree blocks)" ||
    fail "1: setup: no leaf was split -- the workload never filled a leaf"

log "2: lookup cost"
PER="$(per_lookup "$MNT/main" 1)"
[ "$PER" -lt 8 ] && pass "2: $PER tree block read(s) per lookup" ||
    fail "2: $PER tree block reads per lookup -- the leaf ranges overlap"

log "2 control: the same workload with the split off"
ct_param_set leaf_split_off 1
fill "$MNT/ctl" 2
ct_param_set leaf_split_off 0
CTL="$(per_lookup "$MNT/ctl" 2)"
[ "$CTL" -gt $((PER * 3)) ] && [ "$CTL" -ge 8 ] &&
    pass "2 control: without the split a lookup reads $CTL tree blocks (against $PER)" ||
    fail "2 control: without the split a lookup reads $CTL (against $PER) -- the suite cannot tell the split from the append"

log "3: content after a remount, and fsck"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
for f in main:1 ctl:2; do
    out="$(python3 - "$MNT/${f%%:*}" "${f##*:}" "$NBLK" "$NW" <<'PY'
import sys, random
path, seed, nblk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r = random.Random(seed)
written = set(r.randrange(nblk) for _ in range(nw))
bad = 0
zero = bytes(4096)
with open(path, "rb") as fh:
    for b in range(nblk):
        d = fh.read(4096)
        if b in written:
            tag = (b"blk%08d-seed%04d\n" % (b, seed))
            ok = d == (tag * (4096 // len(tag) + 1))[:4096]
        else:
            ok = d == zero
        if not ok:
            bad += 1
            if bad <= 3:
                print("block %d wrong" % b)
print("bad=%d" % bad)
PY
)"
    grep -q "^bad=0$" <<<"$out" && pass "3: ${f%%:*}: every block reads back right after a remount" ||
        fail "3: ${f%%:*}: $(tr '\n' ' ' <<<"$out")"
done
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "3: fsck clean" || fail "3: fsck: $(ct_fsck "$DEV" 2>&1 | grep -m3 ERR | tr '\n' ' ')"
ct_exit
