#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file past a depth-2 tree's leaves grows to depth 3, and every edit of it holds (A-1)
#
# A depth-2 tree held ~258k extents, and a guest's scattered 4 KiB first
# writes into a thin image reached that at about 1 GiB of file: every
# later write needing an extent failed ENOSPC with the volume free
# (audit 2026-11-15 A-1). The format now has a third level -- record ->
# interiors -> interiors -> leaves -- and the writers are depth-generic.
#
# The tree is capped (TEST ONLY tree_root_cap=1, tree_idx_cap=2) so a
# depth-2 tree holds two leaves and depth 3 is reached at a loop device's
# scale: 700 one-block extents, every other block.
#   setup: the file is depth 3;
#   1. every block reads back, every hole as zeros;
#   2. fiemap lists all 700 extents, ascending;
#   3. a punch across leaves (the patch) and one with tree_patch_off=1
#      (the rebuild, which honours the caps too) leave the rest intact;
#   4. appends after the edits still grow the tree and read back;
#   5. after a remount every block reads back; fsck is clean;
#   6. a truncate collapses the tree, the kept data intact, fsck clean;
#   7. create + unlink of a depth-3 file gives every data and tree block
#      back.
#
# DISCRIMINATION: on a module whose tree stops at depth 2 the 509th
# extent fails ENOSPC under these caps -- the build below fails, and the
# setup's depth check with it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_root_cap tree_idx_cap tree_patch_off alloc_run_blocks; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set tree_root_cap 1
ct_param_set tree_idx_cap 2
IPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_dev 2048 d3)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt d3)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
N=700

# The driver keeps $MODEL (the blocks written) current; 'check' reads
# the whole file against it.
DRV="$(ct_tmp d3-drv)"
cat >"$DRV" <<'PY'
import os, sys, ctypes, json
op, path = sys.argv[1], sys.argv[2]
mpath = os.environ["MODEL"]
model = set(json.load(open(mpath))) if os.path.getsize(mpath) else set()
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
if op == "w":  # w <file> <first> <count> <stride>
    first, count, stride = (int(x) for x in sys.argv[3:6])
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    for k in range(count):
        b = first + k * stride
        os.pwrite(fd, stamp(b), b * 4096)
        model.add(b)
    os.fsync(fd)
    os.close(fd)
elif op == "punch":  # punch <file> <block> <count>
    b, n = int(sys.argv[3]), int(sys.argv[4])
    l = ctypes.CDLL("libc.so.6", use_errno=True)
    fd = os.open(path, os.O_RDWR)
    if l.fallocate(fd, 3, ctypes.c_long(b * 4096), ctypes.c_long(n * 4096)) != 0:
        sys.exit("punch: errno %d" % ctypes.get_errno())
    os.close(fd)
    model -= set(range(b, b + n))
elif op == "trunc":  # trunc <file> <blocks>
    n = int(sys.argv[3])
    os.truncate(path, n * 4096)
    model = {b for b in model if b < n}
elif op == "fiemap":  # prints "<mapped> <ascending 0|1>"
    import fcntl, struct, array
    fd = os.open(path, os.O_RDONLY)
    count = 4096
    buf = array.array('B', struct.pack('<QQIIII', 0, 1 << 62, 0, 0, count, 0) + b'\0' * (56 * count))
    fcntl.ioctl(fd, 0xC020660B, buf, True)
    mapped = struct.unpack_from('<I', buf, 20)[0]
    lg = [struct.unpack_from('<Q', buf, 32 + i * 56)[0] for i in range(mapped)]
    os.close(fd)
    print(mapped, int(all(a < b for a, b in zip(lg, lg[1:]))))
    sys.exit(0)
elif op == "check":
    d = open(path, "rb").read()
    bad = [i for i in range(len(d) // 4096)
           if d[i * 4096:(i + 1) * 4096] != (stamp(i) if i in model else b"\0" * 4096)]
    miss = [b for b in model if b * 4096 >= len(d)]
    print("ok" if not bad and not miss else "BAD %d first %s missing %d" % (len(bad), bad[:1], len(miss)))
    sys.exit(0)
json.dump(sorted(model), open(mpath, "w"))
PY
MODEL="$(ct_tmp d3-model)"
export MODEL
: >"$MODEL"
drv() { python3 -I "$DRV" "$@"; }
shape() { "$IPOKE" "$IMG" extents "$1" 2>/dev/null | head -1; }

F="$MNT/frag"
OUT="$(drv w "$F" 0 "$N" 2 2>&1)" || { fail "setup: building $N extents failed: $OUT"; ct_exit; }
INO="$(stat -c %i "$F")"
ct_umount "$MNT"
SHAPE="$(shape "$INO")"
case "$SHAPE" in
depth=3*) pass "setup: the $N-extent file is a depth-3 tree ($SHAPE)" ;;
*)
    fail "setup: the file is not depth 3 -- this suite is not testing it: $SHAPE"
    ct_exit
    ;;
esac
ct_mount "$DEV" "$MNT"

OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "1: every block reads back, every hole as zeros" || fail "1: $OUT"
OUT="$(drv fiemap "$F")"
[ "$OUT" = "$N 1" ] && pass "2: fiemap lists $N extents, ascending" || fail "2: fiemap says '$OUT' (want '$N 1')"

drv punch "$F" 300 41 # blocks 300..340: extents 150..170, across leaves
ct_param_set tree_patch_off 1
drv punch "$F" 1200 41 # the rebuild
ct_param_set tree_patch_off 0
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "3: after a patched and a rebuilt punch the rest reads back, the holes as zeros" ||
    fail "3: $OUT"

drv w "$F" 1801 60 2
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "4: 60 appends after the edits read back" || fail "4: $OUT"

ct_umount "$MNT"
SHAPE="$(shape "$INO")"
case "$SHAPE" in
depth=3*) ;;
*) fail "4 setup: the tree is no longer depth 3 after the edits: $SHAPE" ;;
esac
ct_fsck "$DEV" >/dev/null 2>&1 && pass "5: fsck clean over the depth-3 file" ||
    fail "5: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"
ct_mount "$DEV" "$MNT"
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "5: every block reads back after a remount" || fail "5: $OUT"

drv trunc "$F" 200 # 100 extents stay
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "6: after the truncate the kept data reads back" || fail "6: $OUT"
ct_umount "$MNT"
SHAPE="$(shape "$INO")"
case "$SHAPE" in
depth=0* | depth=1*) pass "6: the truncate collapsed the tree ($SHAPE)" ;;
*) fail "6: the truncate left $SHAPE" ;;
esac
ct_fsck "$DEV" >/dev/null 2>&1 && pass "6: fsck clean after the truncate" ||
    fail "6: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"
ct_mount "$DEV" "$MNT"

sync
FREE0="$(stat -f -c %f "$MNT")"
: >"$MODEL"
drv w "$MNT/frag2" 0 "$N" 2
I2="$(stat -c %i "$MNT/frag2")"
ct_umount "$MNT"
SHAPE="$(shape "$I2")"
case "$SHAPE" in
depth=3*) ;;
*) fail "7 setup: the second file is not depth 3: $SHAPE" ;;
esac
ct_mount "$DEV" "$MNT"
rm "$MNT/frag2"
sync
FREE1="$(stat -f -c %f "$MNT")"
[ "$FREE0" = "$FREE1" ] && pass "7: create + unlink of a depth-3 file leaked nothing ($FREE0 free)" ||
    fail "7: unlink left $((FREE0 - FREE1)) block(s) allocated ($FREE0 -> $FREE1)"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "7: fsck clean at the end" ||
    fail "7: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"
ct_exit
