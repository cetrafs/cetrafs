#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an O_DIRECT write into a hole maps the whole request in one call
#
# A direct write into a hole allocated one block per get_block call, and
# every call began with a lookup that missed -- a walk of every leaf
# whose range covers the block. In a fragmented file (a VM image) that
# made a hole fill 2.5x slower than the same fill in an empty file. Now
# the blocks after the first, as far as the request, the hole and the
# reservation reach, go into the same extent and mapping.
#
# A file of ~2,000 extents (a 4 KiB block every other block), then:
#   1. 32 MiB of 1 MiB O_DIRECT writes into a hole past them: about one
#      lookup miss per request, not per block; the blocks read back;
#   2. a 1 MiB write whose window holds a written block mid-way: the run
#      stops before it, nothing is mapped twice, the data reads back;
#   3. a write that fails right after allocating: the run reads zeros;
#   4. after a remount the same, over free space poisoned with 0xAA;
#      fsck clean.
#
# DISCRIMINATION: dio_hole_run_off=1 (a block per call): one lookup miss
# per block in case 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
[ -w $P/dio_hole_run_off ] || { skip "dio_hole_run_off is missing"; ct_exit; }
[ -w $P/dio_fail_after_alloc_once ] || { skip "dio_fail_after_alloc_once is missing"; ct_exit; }
MNT="$(ct_mnt dhr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set dio_hole_run_off 0
ct_param_set dio_fail_after_alloc_once 0

DRV="$(ct_tmp dhr-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap
op, path = sys.argv[1], sys.argv[2]
B = 4096
FRAG = 2048            # blocks 0, 2, 4 ... 4094: ~2,048 extents
HOLE0 = 8192           # the hole fill: blocks [8192, 16384), 32 MiB
HOLE_N = 8192
MID0 = 20480           # case 2: [20480, 20736), block 20600 written first
MID_W = 20600
FAIL0 = 24576          # case 3: [24576, 24832), the write fails
def stamp(i, gen=0): return (b"B%07d/%d" % (i, gen)).ljust(16, b".") * 256
def wr(f, first, n, gen=0):
    buf = mmap.mmap(-1, n * B)
    for k in range(n):
        buf[k * B:(k + 1) * B] = stamp(first + k, gen)
    return os.pwritev(f, [buf], first * B)
if op == "frag":
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    os.ftruncate(f, 32768 * B)
    for i in range(FRAG):
        wr(f, 2 * i, 1)
    wr(f, MID_W, 1, 1)
    os.fsync(f); os.close(f)
elif op == "fill":
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    for c in range(HOLE_N // 256):
        wr(f, HOLE0 + c * 256, 256)
    os.fsync(f); os.close(f)
elif op == "mid":
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    wr(f, MID0, 256, 2)
    os.fsync(f); os.close(f)
elif op == "fail":
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    try:
        wr(f, FAIL0, 256, 3)
        print("nofail")
    except OSError as e:
        print("failed_%d" % e.errno)
    os.close(f)
elif op == "check":
    d = open(path, "rb").read()
    want = {}
    for i in range(FRAG): want[2 * i] = stamp(2 * i)
    for i in range(HOLE0, HOLE0 + HOLE_N): want[i] = stamp(i)
    for i in range(MID0, MID0 + 256): want[i] = stamp(i, 2)
    bad = [i for i in range(len(d) // B) if d[i * B:(i + 1) * B] != want.get(i, bytes(B))]
    aa = sum(1 for i in bad if d[i * B:i * B + 1] == b"\xaa")
    print("ok" if not bad and len(d) == 32768 * B else "BAD_%d_first_%s_stale_%d" % (len(bad), bad[:3], aa))
PY
info() { sed -n "s/^$1: //p" "$PROC/info"; }
# Extent RECORDS: filefrag's summary merges records that are physically
# adjacent, and the fragmenting writes are (one block every other block,
# allocated back to back).
extents() {
    local out
    out="$(filefrag -v "$1")"
    grep -cE '^ *[0-9]+: ' <<<"$out" || true
}

# <tag> <off 0|1> -> RES
round() {
    local img dev m0 r0 b0 fl
    img="$(ct_image 560 "dhr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    # Free space poisoned: a run block that should read zeros and was
    # mapped as written reads 0xAA.
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
chunk = b"\xaa" * (1 << 20)
for i in range(300):
    os.write(fd, chunk)
os.fsync(fd); os.close(fd)' "$MNT/poison"
    rm -f "$MNT/poison"
    sync
    # The fragmenting writes must stay one block each.
    ct_param_set sparse_unit_off 1
    python3 -I "$DRV" frag "$MNT/f"
    ct_param_set sparse_unit_off 0
    RES="frag_ext=$(extents "$MNT/f")"
    echo "$2" >$P/dio_hole_run_off
    m0="$(info ext_cache_misses)"
    r0="$(info dio_hole_runs)"
    b0="$(info dio_hole_run_blocks)"
    python3 -I "$DRV" fill "$MNT/f"
    RES="$RES misses=$(($(info ext_cache_misses) - m0)) runs=$(($(info dio_hole_runs) - r0)) run_blocks=$(($(info dio_hole_run_blocks) - b0))"
    python3 -I "$DRV" mid "$MNT/f"
    echo 1 >$P/dio_fail_after_alloc_once
    fl="$(python3 -I "$DRV" fail "$MNT/f")"
    echo 0 >$P/dio_fail_after_alloc_once
    echo 0 >$P/dio_hole_run_off
    RES="$RES fail=$fl data=$(python3 -I "$DRV" check "$MNT/f")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="$RES rdata=$(python3 -I "$DRV" check "$MNT/f")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}
get() { sed -nE "s/(^|.* )$1=([^ ]*).*/\2/p" <<<"$2"; }

round c 1
C="$RES"
log "control (a block per call): $C"
round f 0
R="$RES"
log "runs: $R"
[ "$(get frag_ext "$C")" -ge 1500 ] && [ "$(get frag_ext "$R")" -ge 1500 ] ||
    fail "setup: the file did not fragment ($C / $R) -- the suite cannot see the lookups"
[ "$(get misses "$C")" -ge 4096 ] && [ "$(get runs "$C")" = 0 ] &&
    pass "control: a block per call misses $(get misses "$C") times for 8192 blocks" ||
    fail "control: $C -- the suite cannot tell a run from a block"
[ "$(get misses "$R")" -le 256 ] && [ "$(get runs "$R")" -ge 32 ] && [ "$(get run_blocks "$R")" -ge 7900 ] &&
    pass "1: 32 MiB into a hole of a $(get frag_ext "$R")-extent file: $(get misses "$R") lookup misses, $(get runs "$R") runs" ||
    fail "1: $R"
for t in R C; do
    v="${!t}"
    [ "$(get fail "$v")" = failed_5 ] || fail "3 ($t): the injected failure did not fire ($(get fail "$v"))"
    [ "$(get data "$v")" = ok ] && [ "$(get rdata "$v")" = ok ] && [ "$(get fsck_err "$v")" = 0 ] &&
        pass "2-4 ($t): hole fill, a write across a written block and a failed write read back right, before and after a remount; fsck clean" ||
        fail "2-4 ($t): $v"
done
ct_exit
