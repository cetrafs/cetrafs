#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a sparse unit never leaves more extents than a block alone would
#
# A first write into a sparse hole allocates its aligned 64 KiB unit as
# one preallocated extent, and its convert marks the unit written. When
# the unit cannot be widened, that convert splits it -- three extents
# where the block alone made one (audit 2026-11-15 F-18):
#   W. a device without WRITE ZEROES never widens: every unit split, and
#      a thin image reached the extent ceiling at a third of the scatter.
#      Units are now allocated only where the device can zero them.
#   H. a sibling write into the same unit still in flight: the first
#      convert splits the unit, and every later write into it split it
#      again. The last write into the unit now heals it -- zeroes and
#      converts what is still preallocated -- back to one extent.
#
#   W: 800 scattered O_DIRECT first writes into 100 units of a sparse
#      file on a dm-crypt (null cipher) map, which has no WRITE ZEROES:
#      no more extents than writes; data back, the rest zeros; fsck clean.
#   H: write A into a fresh unit held in flight while write B into the
#      same unit completes, then A completes: the unit is one extent, both
#      blocks read back, the rest zeros; fsck clean.
#
# DISCRIMINATION: W with sparse_unit_zeroes_check_off=1: about three
# extents per write. H with convert_heal_off=1: the unit stays split.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in sparse_unit_zeroes_check_off convert_heal_off dio_end_io_stall_ms sparse_unit_off; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
modprobe dm_crypt 2>/dev/null || true
# H zeroes with WRITE ZEROES, which a loop device serves as
# FALLOC_FL_ZERO_RANGE on its backing file.
export CT_IMG_DIR="${CT_IMG_DIR:-/var/tmp}"
ZR="$(mktemp "$CT_IMG_DIR/cetrafs-zr-XXXXXX")"
truncate -s 1M "$ZR"
if ! fallocate -z -o 0 -l 65536 "$ZR" 2>/dev/null; then
    rm -f "$ZR"
    skip "$CT_IMG_DIR cannot zero a range in place (FALLOC_FL_ZERO_RANGE) -- set CT_IMG_DIR to one that can"
    ct_exit
fi
rm -f "$ZR"
AIO="$(ct_helper dio_aio)"
MNT="$(ct_mnt spns)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set convert_unit_blocks 16
ct_param_set sparse_unit_off 0
ct_param_set sparse_unit_zeroes_check_off 0
ct_param_set convert_heal_off 0
ct_param_set dio_end_io_stall_ms 0

DRV="$(ct_tmp spns-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, random
op, path = sys.argv[1], sys.argv[2]
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
rng = random.Random(11)
us = rng.sample(range(1, 256), 100)
blocks = sorted({u * 16 + o for u in us for o in rng.sample(range(16), 8)})
order = blocks[:]
rng.shuffle(order)
if op == "write":
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    os.ftruncate(f, 256 * 16 * 4096)
    buf = mmap.mmap(-1, 4096)
    for b in order:
        buf.seek(0); buf.write(stamp(b))
        os.pwritev(f, [buf], b * 4096)
    os.fsync(f)
    os.close(f)
    print(len(blocks))
else:
    want = set(blocks)
    d = open(path, "rb").read()
    bad = [i for i in range(len(d) // 4096) if d[i * 4096:(i + 1) * 4096] != (stamp(i) if i in want else bytes(4096))]
    print("ok" if not bad else "BAD_%d" % len(bad))
PY
ctrs() { awk -F': ' '$1 ~ /^(convert_units_(widened|healed|busy)|sparse_units)$/ { printf "%s=%s ", $1, $2 }' "$PROC/info"; }
# Raw FIEMAP records, not filefrag's count: filefrag merges records that
# are physically contiguous, and a split unit is -- one run on the device,
# three entries in the tree, and the tree's entries are what reach the
# ceiling.
extents() {
    python3 -I - "$1" <<'PY2'
import fcntl, struct, sys
FS_IOC_FIEMAP = 0xC020660B
n, start = 0, 0
with open(sys.argv[1], "rb") as f:
    while True:
        req = bytearray(struct.pack("=QQIIII", start, 0xFFFFFFFFFFFFFFFF - start, 0, 0, 256, 0) + bytes(56 * 256))
        fcntl.ioctl(f, FS_IOC_FIEMAP, req)
        got = struct.unpack_from("=I", req, 20)[0]
        if not got:
            break
        n += got
        last = 32 + 56 * (got - 1)
        lo, _, ln = struct.unpack_from("=QQQ", req, last)
        flags = struct.unpack_from("=I", req, last + 40)[0]
        if flags & 1:  # FIEMAP_EXTENT_LAST
            break
        start = lo + ln
print(n)
PY2
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# --- W ----------------------------------------------------------------------
# <tag> <check_off 0|1> -> RES
wround() {
    local img loop name dev wz n
    img="$(ct_image 560 "spnw$1")"
    loop="$(ct_loop "$img")"
    name="ctspnw$1$$"
    dmsetup create "$name" --table "0 $(blockdev --getsz "$loop") crypt cipher_null-ecb - 0 $loop 0" ||
        { skip "dm-crypt (cipher_null) is not available"; ct_exit; }
    ct_track dm "$name"
    dev="/dev/mapper/$name"
    udevadm settle 2>/dev/null || true
    wz="$(cat "/sys/block/$(basename "$(readlink -f "$dev")")/queue/write_zeroes_max_bytes")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    echo "$2" >$P/sparse_unit_zeroes_check_off
    n="$(python3 -I "$DRV" write "$MNT/f")"
    echo 0 >$P/sparse_unit_zeroes_check_off
    RES="wz=$wz writes=$n ext=$(extents "$MNT/f") data=$(python3 -I "$DRV" check "$MNT/f") $(ctrs)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}

# --- H ----------------------------------------------------------------------
# <tag> <heal_off 0|1> -> RES
hround() {
    local img dev out
    img="$(ct_image 560 "spnh$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    # Free space poisoned: a block the heal failed to zero reads 0xAA.
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
chunk = b"\xaa" * (1 << 20)
for i in range(400):
    os.write(fd, chunk)
os.fsync(fd); os.close(fd)' "$MNT/poison"
    rm -f "$MNT/poison"
    sync
    truncate -s $((64 * 4096)) "$MNT/g"
    echo "$2" >$P/convert_heal_off
    echo 1500 >$P/dio_end_io_stall_ms
    out="$("$AIO" unit "$MNT/g" 19 25 200)"
    echo 0 >$P/dio_end_io_stall_ms
    echo 0 >$P/convert_heal_off
    RES="$out ext=$(extents "$MNT/g") $(ctrs)"
    RES="$RES rest=$(python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read()
print(sum(1 for i in range(len(d) // 4096) if i not in (19, 25) and d[i*4096:(i+1)*4096] != bytes(4096)))' "$MNT/g")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}

wround c 1
WC="$RES"
log "W control (units without WRITE ZEROES): $WC"
wround f 0
WR="$RES"
log "W fixed: $WR"
[ "$(get wz "$WR")" = 0 ] || { fail "W setup: the dm-crypt map advertises WRITE ZEROES ($WR)"; ct_exit; }
[ "$(get ext "$WR")" -le "$(get writes "$WR")" ] && [ "$(get data "$WR")" = ok ] && [ "$(get fsck_err "$WR")" = 0 ] &&
    pass "W: $(get writes "$WR") scattered writes on a device without WRITE ZEROES left $(get ext "$WR") extents; data back; fsck clean" ||
    fail "W: $WR"
[ "$(get ext "$WC")" -gt "$(get writes "$WC")" ] &&
    pass "W control: units there left $(get ext "$WC") extents for $(get writes "$WC") writes" ||
    fail "W control: units without WRITE ZEROES did not split ($WC) -- the suite cannot see it"

hround c 1
HC="$RES"
log "H control (no heal): $HC"
hround f 0
HR="$RES"
log "H fixed: $HR"
[ "$(get a_inflight "$HR")" = 1 ] && [ "$(get a_inflight "$HC")" = 1 ] ||
    { fail "H setup: A completed before B -- the stall did not hold it ($HR | $HC)"; ct_exit; }
[ "$(get ext "$HR")" = 1 ] && [ "$(get a "$HR")" = A ] && [ "$(get b "$HR")" = B ] && [ "$(get rest "$HR")" = 0 ] &&
    [ "$(get fsck_err "$HR")" = 0 ] &&
    pass "H: the split unit healed to one extent; both writes back, the rest zeros; fsck clean" || fail "H: $HR"
[ "$(get ext "$HC")" -ge 3 ] &&
    pass "H control: without the heal the unit stays $(get ext "$HC") extents" ||
    fail "H control: the unit was not split ($HC) -- the suite does not reach the busy convert"
ct_exit
