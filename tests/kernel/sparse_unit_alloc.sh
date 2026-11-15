#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# scattered first writes into a sparse file allocate a 64 KiB unit, not a block
#
# A first write into a hole allocated its one block: scattered 4 KiB
# writes into a thin image -- a database, a guest filesystem -- made one
# extent each, and the tree's 258,064-extent ceiling came after about
# 1 GiB of scatter (audit 2026-11-15 A-1, G-1). Such a write now
# allocates the aligned unit around it as one preallocated extent, and
# its convert marks the unit written, zeroing the rest.
#
# 4,000 random 4 KiB first writes, eight into each of 500 units, into a
# sparse file over free space poisoned with 0xAA, once with O_DIRECT and
# once buffered (fsync at the end):
#   1. about one extent per unit, not one per write;
#   2. every written block reads back, every other block reads zeros --
#      before and after a remount; fsck clean;
#   3. a sequential fill of a new file allocates no unit (nothing to
#      zero ahead of a writer that is about to write it).
#
# DISCRIMINATION: sparse_unit_off=1 (a block per first write): one extent
# per write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/sparse_unit_off ] || { skip "sparse_unit_off is missing"; ct_exit; }
# A unit is zeroed with WRITE ZEROES, which a loop device serves as
# FALLOC_FL_ZERO_RANGE on its backing file; without it no unit is
# allocated at all (sparse_unit_no_split.sh).
export CT_IMG_DIR="${CT_IMG_DIR:-/var/tmp}"
ZR="$(mktemp "$CT_IMG_DIR/cetrafs-zr-XXXXXX")"
truncate -s 1M "$ZR"
if ! fallocate -z -o 0 -l 65536 "$ZR" 2>/dev/null; then
    rm -f "$ZR"
    skip "$CT_IMG_DIR cannot zero a range in place (FALLOC_FL_ZERO_RANGE) -- set CT_IMG_DIR to one that can"
    ct_exit
fi
rm -f "$ZR"
MNT="$(ct_mnt spu)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set convert_unit_blocks 16
ct_param_set sparse_unit_off 0
P=/sys/module/cetrafs/parameters
UNITS=500
PER=8

DRV="$(ct_tmp spu-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, random
op, path, units, per = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
rng = random.Random(7)
# units spread over 64 MiB (1024 units), eight random blocks in each, in random order
us = rng.sample(range(1, 1024), units)
blocks = sorted({u * 16 + o for u in us for o in rng.sample(range(16), per)})
order = blocks[:]
rng.shuffle(order)
if op in ("dio", "buf"):
    flags = os.O_RDWR | os.O_CREAT | (os.O_DIRECT if op == "dio" else 0)
    f = os.open(path, flags, 0o644)
    os.ftruncate(f, 1024 * 16 * 4096)
    buf = mmap.mmap(-1, 4096)
    for b in order:
        buf.seek(0); buf.write(stamp(b))
        os.pwritev(f, [buf], b * 4096)
    os.fsync(f)
    os.close(f)
elif op == "check":
    want = set(blocks)
    d = open(path, "rb").read()
    bad = [i for i in range(len(d) // 4096) if d[i * 4096:(i + 1) * 4096] != (stamp(i) if i in want else bytes(4096))]
    aa = sum(1 for i in bad if d[i * 4096:i * 4096 + 1] == b"\xaa")
    print("ok" if not bad and len(d) == 1024 * 16 * 4096 else "BAD_%d_stale_%d" % (len(bad), aa))
PY
extents() { filefrag "$1" | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p'; }
info() { sed -n "s/^$1: //p" "$PROC/info"; }

# <tag> <off 0|1> -> RES
round() {
    local img dev u0 seq
    img="$(ct_image 560 "spu$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    # Free space poisoned: a block the unit failed to zero reads 0xAA.
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
chunk = b"\xaa" * (1 << 20)
for i in range(400):
    os.write(fd, chunk)
os.fsync(fd); os.close(fd)' "$MNT/poison"
    rm -f "$MNT/poison"
    sync
    echo "$2" >$P/sparse_unit_off
    u0="$(info sparse_units)"
    python3 -I "$DRV" dio "$MNT/d" "$UNITS" "$PER"
    python3 -I "$DRV" buf "$MNT/b" "$UNITS" "$PER"
    RES="units=$(($(info sparse_units) - u0)) dio_ext=$(extents "$MNT/d") buf_ext=$(extents "$MNT/b")"
    u0="$(info sparse_units)"
    dd if=/dev/urandom of="$MNT/seq" bs=4096 count=2048 oflag=direct status=none
    seq=$(($(info sparse_units) - u0))
    echo 0 >$P/sparse_unit_off
    RES="$RES seqn=$seq seq_ext=$(extents "$MNT/seq")"
    RES="$RES dio=$(python3 -I "$DRV" check "$MNT/d" "$UNITS" "$PER") buf=$(python3 -I "$DRV" check "$MNT/b" "$UNITS" "$PER")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="$RES rdio=$(python3 -I "$DRV" check "$MNT/d" "$UNITS" "$PER") rbuf=$(python3 -I "$DRV" check "$MNT/b" "$UNITS" "$PER")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

round c 1
C="$RES"
log "control (a block per first write): $C"
round f 0
R="$RES"
log "units: $R"
[ "$(get dio_ext "$C")" -ge $((UNITS * PER / 2)) ] && [ "$(get buf_ext "$C")" -ge $((UNITS * PER / 2)) ] &&
    pass "control: a block per first write leaves $(get dio_ext "$C") / $(get buf_ext "$C") extents" ||
    fail "control: the scatter did not fragment the file ($C) -- the suite cannot see the units"
[ "$(get units "$R")" -ge "$UNITS" ] && [ "$(get dio_ext "$R")" -le $((UNITS + UNITS / 10)) ] &&
    [ "$(get buf_ext "$R")" -le $((UNITS + UNITS / 10)) ] &&
    pass "1: $((UNITS * PER)) scattered writes into $UNITS units left $(get dio_ext "$R") (O_DIRECT) / $(get buf_ext "$R") (buffered) extents" ||
    fail "1: $R"
[ "$(get dio "$R")" = ok ] && [ "$(get buf "$R")" = ok ] && [ "$(get rdio "$R")" = ok ] && [ "$(get rbuf "$R")" = ok ] &&
    [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: written blocks read back, the rest zeros, before and after a remount; fsck clean" || fail "2: $R"
[ "$(get seqn "$R")" = 0 ] && [ "$(get seq_ext "$R")" -le 4 ] &&
    pass "3: a sequential fill allocated no unit ($(get seq_ext "$R") extents)" || fail "3: $R"
ct_exit
