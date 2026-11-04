#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an O_DIRECT write into a hole or preallocated space stays direct
#
# blockdev_direct_IO() maps writes inside i_size with create == 0
# (DIO_SKIP_HOLES), so a write that landed on a hole or on a preallocated
# block came back unmapped, the DIO code gave up on it (-ENOTBLK), and
# the VFS finished it through the page cache plus a synchronous flush --
# under inode_lock, one at a time. Every 4 KiB write into a sparse file
# ran at queue depth 1: 1,232-1,510 IOPS against ~22,000 for overwrites
# of the same file on two real arrays, and 143 IOPS into fallocated space
# on a 2 ms delay device.
#
# Now such a write maps with create == 1: a preallocated block as it is,
# a hole allocated PREALLOCATED, and the write's completion converts the
# range once the data has landed (cetrafs_dio_end_io()). Until then the
# blocks read as zeros -- which is what keeps a crash, a reader or a peer
# from seeing whatever the block held before.
#
# The fallback is counted exactly (dio_fallbacks: an O_DIRECT iocb
# reaching write_begin), so "it stayed direct" is not inferred from
# timing. The timing is asserted too, on a delay device, because queue
# depth is the thing that was lost.
#
# DISCRIMINATION: dio_fill_holes=0 restores the fallback and must move
# the counter; dio_skip_convert=1 leaves a completed write unconverted
# and its data must then read as zeros -- the conversion is what makes a
# write visible. The deadlock section has NO negative control: with the
# old lock order (invalidate_lock held across inode_dio_wait()) the punch
# and the completion it waits for both sleep uninterruptibly, so the
# control would wedge the test box. It detects a hang by deadline rather
# than by `timeout`, which cannot kill a task in D state.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dio_fill_holes dio_skip_convert auto_defrag; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

DEV="$(ct_delay_dev 560 3 diofill)"
[ -n "$DEV" ] || { skip "dm-delay is not available"; ct_exit; }
MNT="$(ct_mnt diofill)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }
# The janitor rewrites extents on its own schedule; keep it out of the
# extent counts below.
ct_param_set auto_defrag 0

# Free space full of a marker, so a block that becomes readable before
# its data is written shows it.
python3 -c '
import os, sys
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
b = b"SECRET!!" * 512
for i in range(4096):
    os.write(f, b)
os.fsync(f); os.close(f)
' "$MNT/seed"
rm "$MNT/seed"
sync

# write <path> <hole|falloc> <file_blocks> <n> <seed>: n random 4 KiB
# O_DIRECT writes, each block stamped with its own number; then read the
# whole file back, O_DIRECT and buffered, and check every block: written
# ones carry their stamp, the rest are zeros.
PY='
import os, sys, mmap, ctypes, random
def ab(n, align=4096):
    b = mmap.mmap(-1, n + align)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % align
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
path, mode, nb, n, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
if os.path.exists(path): os.unlink(path)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if mode == "falloc": os.posix_fallocate(fd, 0, nb * 4096)
else: os.ftruncate(fd, nb * 4096)
os.close(fd)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
random.seed(seed)
blocks = sorted(random.sample(range(nb), n))
b, o = ab(4096)
order = blocks[:]; random.shuffle(order)
for i in order:
    b[o:o+4096] = stamp(i)
    assert os.pwrite(fd, memoryview(b)[o:o+4096], i * 4096) == 4096
os.close(fd)
def check(direct):
    fd = os.open(path, os.O_RDONLY | (os.O_DIRECT if direct else 0))
    r, ro = ab(4096)
    want = set(blocks); bad = []
    for i in range(nb):
        got = os.preadv(fd, [memoryview(r)[ro:ro+4096]], i * 4096)
        d = bytes(r[ro:ro+4096])
        exp = stamp(i) if i in want else b"\0" * 4096
        if got != 4096 or d != exp:
            bad.append("%d:%s" % (i, "SECRET" if b"SECRET" in d else ("zeros" if d == b"\0"*4096 else "other")))
    os.close(fd)
    return bad
for direct in (True, False):
    bad = check(direct)
    print("%s:%s" % ("direct" if direct else "buffered", "ok" if not bad else "BAD %d %s" % (len(bad), " ".join(bad[:5]))))
'
for mode in hole falloc; do
    log "$mode: 300 random 4 KiB O_DIRECT writes"
    F0="$(ctr dio_fallbacks)"
    C0="$(ctr dio_converts)"
    OUT="$(python3 -c "$PY" "$MNT/$mode" "$mode" 8192 300 7)"
    F1="$(ctr dio_fallbacks)"
    C1="$(ctr dio_converts)"
    [ "$F1" = "$F0" ] && pass "$mode: none of them fell back to the page cache" ||
        fail "$mode: $((F1 - F0)) write(s) fell back to the page cache"
    [ "$((C1 - C0))" -ge 300 ] && pass "$mode: each completion converted its block ($((C1 - C0)))" ||
        fail "$mode: only $((C1 - C0)) completions converted anything -- the writes did not take the new path"
    grep -q "^direct:ok" <<<"$OUT" && pass "$mode: every block reads back right through O_DIRECT" ||
        fail "$mode: O_DIRECT read-back: $(grep '^direct' <<<"$OUT")"
    grep -q "^buffered:ok" <<<"$OUT" && pass "$mode: and through the page cache" ||
        fail "$mode: buffered read-back: $(grep '^buffered' <<<"$OUT")"
done

log "after a remount: the conversions were published"
for mode in hole falloc; do
    python3 -c "$PY" "$MNT/$mode.chk" "$mode" 1024 100 9 >/dev/null
done
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
for mode in hole falloc; do
    OUT="$(python3 -c '
import os, sys, random
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
path, nb, n, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
random.seed(seed)
blocks = set(random.sample(range(nb), n))
d = open(path, "rb").read()
bad = [i for i in range(nb) if d[i*4096:(i+1)*4096] != (stamp(i) if i in blocks else b"\0"*4096)]
print("ok" if not bad else "BAD %d first %d" % (len(bad), bad[0]))
' "$MNT/$mode.chk" 1024 100 9)"
    [ "$OUT" = "ok" ] && pass "$mode: the data and the zeros survive a remount" ||
        fail "$mode: after a remount: $OUT"
done

log "a 512-byte O_DIRECT write into a hole and into preallocated space"
OUT="$(python3 -c '
import os, sys, mmap, ctypes
def ab(n, align=4096):
    b = mmap.mmap(-1, n + align)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % align
for mode in ("hole", "falloc"):
    p = sys.argv[1] + "/sub" + mode
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    if mode == "falloc": os.posix_fallocate(fd, 0, 1 << 20)
    else: os.ftruncate(fd, 1 << 20)
    os.close(fd)
    fd = os.open(p, os.O_RDWR | os.O_DIRECT)
    b, o = ab(512); b[o:o+512] = b"A" * 512
    os.pwrite(fd, memoryview(b)[o:o+512], 65536 + 3584)
    os.close(fd)
    d = open(p, "rb").read()[65536:65536+4096]
    print("%s:%s" % (mode, "ok" if d == b"\0"*3584 + b"A"*512 else ("SECRET" if b"SECRET" in d else "wrong")))
' "$MNT")"
for mode in hole falloc; do
    grep -q "^$mode:ok" <<<"$OUT" && pass "$mode: the rest of the block reads as zeros, not as what it held" ||
        fail "$mode: sub-block write: $(grep "^$mode" <<<"$OUT")"
done

log "control: dio_fill_holes=0 restores the fallback, and the counter sees it"
# Put back what was there, not "1": a hard-coded value here made every
# later section run the new path whatever the default was, and the queue
# depth assertion passed against the old code.
WAS="$(cat /sys/module/cetrafs/parameters/dio_fill_holes)"
ct_param_set dio_fill_holes 0
F0="$(ctr dio_fallbacks)"
OUT="$(python3 -c "$PY" "$MNT/ctl" hole 1024 20 3)"
F1="$(ctr dio_fallbacks)"
ct_param_set dio_fill_holes "$WAS"
[ "$F1" -gt "$F0" ] && pass "control: the old path falls back ($((F1 - F0)) writes), and dio_fallbacks counts it" ||
    fail "control: dio_fill_holes=0 did not move dio_fallbacks -- the counter observes nothing"
grep -q "^direct:ok" <<<"$OUT" || fail "control: the old path read back wrong: $OUT"

log "control: an unconverted completion leaves the data invisible"
ct_param_set dio_skip_convert 1
OUT="$(python3 -c "$PY" "$MNT/noconv" hole 64 4 5)"
ct_param_set dio_skip_convert 0
grep -q "^direct:BAD 4 .*zeros" <<<"$OUT" &&
    pass "control: without the conversion the written blocks read as zeros -- the conversion is what publishes" ||
    fail "control: dio_skip_convert=1 still read back as: $OUT"

if command -v fio >/dev/null 2>&1; then
    FIO=(fio --ioengine=libaio --direct=1 --output-format=json --name=t)
    iops() { python3 -c 'import json,sys; print(int(sum(j["write"]["iops"] for j in json.load(sys.stdin)["jobs"])))'; }

    log "a sequential fill of a hole stays one extent"
    # 64 KiB writes, 16 in flight: thousands of completions, converted in
    # whatever order they land. Without the in-leaf coalescing this ends
    # at 4-5 extents (and at ~190 without the allocation hint as well);
    # with both, 1.
    truncate -s 256M "$MNT/seq"
    "${FIO[@]}" --filename="$MNT/seq" --size=256M --rw=write --bs=64k --iodepth=16 >/dev/null
    EXT="$(filefrag "$MNT/seq" | awk '{print $2}')"
    [ "$EXT" -le 2 ] && pass "sequential: 256 MiB in $EXT extent(s), completions out of order or not" ||
        fail "sequential: 256 MiB in $EXT extents -- out-of-order conversions fragmented it"
    rm -f "$MNT/seq"

    log "queue depth: writes into a hole overlap again"
    F0="$(ctr dio_fallbacks)"
    truncate -s 256M "$MNT/qd1"
    Q1="$("${FIO[@]}" --filename="$MNT/qd1" --size=256M --rw=randwrite --bs=4k --iodepth=1 --runtime=4 --time_based | iops)"
    truncate -s 256M "$MNT/qd16"
    Q16="$("${FIO[@]}" --filename="$MNT/qd16" --size=256M --rw=randwrite --bs=4k --iodepth=16 --runtime=4 --time_based | iops)"
    F1="$(ctr dio_fallbacks)"
    [ "$F1" = "$F0" ] || fail "queue depth: $((F1 - F0)) write(s) fell back"
    [ "$Q16" -ge "$((Q1 * 4))" ] && pass "queue depth: QD16 does $Q16 IOPS against $Q1 at QD1 on a 3 ms device" ||
        fail "queue depth: QD16 does $Q16 IOPS against $Q1 at QD1 -- the writes are still serialised"
    rm -f "$MNT/qd1" "$MNT/qd16"

    log "data integrity with 32 writes in flight"
    truncate -s 64M "$MNT/verify"
    if "${FIO[@]}" --filename="$MNT/verify" --size=64M --rw=randwrite --bs=4k --iodepth=32 --verify=crc32c \
        --do_verify=1 --verify_fatal=1 --verify_state_save=0 >"$(ct_tmp diofill-verify)" 2>&1; then
        pass "integrity: fio's crc32c verify of every block written at QD32 passes"
    else
        fail "integrity: fio verify failed"
    fi

    log "hole punches while direct writes are in flight do not deadlock"
    # A completion takes invalidate_lock to convert; a punch used to hold
    # that lock while waiting for in-flight direct I/O.
    truncate -s 64M "$MNT/punch"
    "${FIO[@]}" --filename="$MNT/punch" --size=64M --rw=randwrite --bs=4k --iodepth=32 --runtime=6 \
        --time_based >/dev/null 2>&1 &
    W=$!
    sleep 1
    HUNG=0
    for i in $(seq 1 30); do
        fallocate -p -o $(((RANDOM % 1000) * 65536)) -l 65536 "$MNT/punch" &
        P=$!
        for _ in $(seq 1 400); do kill -0 "$P" 2>/dev/null || break; sleep 0.05; done
        kill -0 "$P" 2>/dev/null && { HUNG=1; break; }
        wait "$P" || true
    done
    if [ "$HUNG" = 1 ]; then
        fail "punch: a punch did not complete in 20 s beside in-flight direct writes (left in D state)"
        ct_exit
    fi
    wait "$W" && FOK=1 || FOK=0
    pass "punch: 30 punches completed beside 32 in-flight writes"
    [ "$FOK" = 1 ] && pass "punch: and the writer finished cleanly" || fail "punch: fio failed beside the punches"
else
    skip "fio is missing: queue depth, extent count, integrity and punch sections not run"
fi

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
