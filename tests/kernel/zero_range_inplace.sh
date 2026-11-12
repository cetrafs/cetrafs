#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate(ZERO_RANGE) zeroes written data in place: no block freed, none reallocated, the layout unchanged
#
# ZERO_RANGE was a punch then a preallocation: every whole block of a
# written range was freed and a new one allocated somewhere else. On an
# FC array a qemu-style stream of 1 MiB write-zeroes ran at 40 ops/s and
# took an image from 9 extents to 6264 (docs/internal/ZERO-RANGE-
# BENCHMARK.md). Where the device can zero (REQ_OP_WRITE_ZEROES) the
# written blocks are now zeroed where they are
# (cetrafs_zero_range_inplace()).
#
#  1. an unaligned range over written data: every byte matches the model,
#     buffered, O_DIRECT and after a remount; the physical layout
#     (filefrag) is byte-identical; zero_inplace_blocks counted exactly
#     the range's whole blocks.
#  2. dirty page-cache data inside the range, its file still open, is
#     not written back over the zeros at close.
#  3. a store through a shared mapping made before the call is gone
#     after it: the mapping reads the zeros.
#  4. a buffered write into preallocated space, on the device but its
#     conversion still pending, is not published as written at the close
#     after the zeroing.
#  5. a range across written data, preallocated space, a hole and EOF
#     (no KEEP_SIZE): the size grows, it all reads zero, it is allocated.
#  6. NEGATIVE CONTROL: with zero_inplace_off (the old path) case 1's
#     layout check fails -- the check sees a reallocation.
#  7. fsck is clean.
#
# DISCRIMINATION: 6 is the control for 1's layout check. With the
# page-cache drop removed from cetrafs_zero_range_inplace() 2 and 3 fail;
# with the pending-set clear removed, 4 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fallocate >/dev/null || { skip "no fallocate(1)"; ct_exit; }
command -v filefrag >/dev/null || { skip "no filefrag(8)"; ct_exit; }

DEV="$(ct_dev 560 zrinpl)"
MNT="$(ct_mnt zrinpl)"
[ "$(cat "/sys/block/$(basename "$(readlink -f "$DEV")")/queue/write_zeroes_max_bytes")" != 0 ] ||
    { skip "this loop device cannot zero in place (backing fs?)"; ct_exit; }
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
F="$MNT/img"
MODEL="$(ct_tmp zrimodel)"
ERR="$(ct_tmp zrierr)"

info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
# The physical layout: every extent's logical and physical range.
layout() { filefrag -v "$F" | awk '$1 ~ /^[0-9]+:$/ { print $2, $3, $4, $5, $6 }'; }

# check <case>: the file matches the model, buffered and O_DIRECT.
check() {
    local c="$1" r
    r="$(python3 -I - "$F" "$MODEL" <<'PY'
import mmap, os, sys
want = open(sys.argv[2], "rb").read()
got = open(sys.argv[1], "rb").read()
if got != want:
    n = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]), min(len(got), len(want)))
    print("buffered: differs at byte %d (size %d, model %d)" % (n, len(got), len(want))); sys.exit()
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
size = os.fstat(fd).st_size
buf = mmap.mmap(-1, (size + 4095) // 4096 * 4096)
os.readv(fd, [buf]); os.close(fd)
if bytes(buf[:size]) != want:
    n = next(i for i in range(size) if buf[i] != want[i])
    print("O_DIRECT: differs from the model at byte %d" % n); sys.exit()
print("ok")
PY
)"
    [ "$r" = ok ] && pass "$c: every byte matches the model (buffered and O_DIRECT)" || fail "$c: $r"
}
model_zero() { # <off> <len> [extend]
    python3 -I - "$MODEL" "$1" "$2" "${3:-}" <<'PY'
import sys
p, off, ln, ext = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
b = bytearray(open(p, "rb").read())
end = off + ln
if ext and end > len(b):
    b.extend(bytes(end - len(b)))
end = min(end, len(b))
b[off:end] = bytes(max(0, end - off))
open(p, "wb").write(bytes(b))
PY
}
remount() { ct_umount "$MNT"; ct_mount "$DEV" "$MNT"; }

# open_write_zero <off> <len> <push>: write random data buffered at
# <off>, then ZERO_RANGE it through the SAME descriptor, as qemu does,
# and only then close. Not fallocate(1): its own open writes the dirty
# pages back and settles the pending conversions before the zeroing
# runs, and the case then tests nothing. With push=1 the
# data is first written to the device with sync_file_range(), which
# settles nothing: a preallocated block then holds the data on the
# device and only its pending conversion stands between it and a read.
open_write_zero() {
    python3 -I - "$F" "$1" "$2" "$3" <<'PY'
import ctypes, os, sys
f, off, ln, push = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
fd = os.open(f, os.O_RDWR)
os.pwrite(fd, os.urandom(ln), off)
if push:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.sync_file_range.argtypes = [ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong, ctypes.c_uint]
    # WAIT_BEFORE | WRITE | WAIT_AFTER
    if libc.sync_file_range(fd, off, ln, 7) != 0:
        print("sync_file_range: errno %d" % ctypes.get_errno()); sys.exit()
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]
# FALLOC_FL_ZERO_RANGE | FALLOC_FL_KEEP_SIZE
rc = libc.fallocate(fd, 0x10 | 0x1, off, ln)
err = ctypes.get_errno()
os.close(fd)
print("ok" if rc == 0 else "fallocate failed: errno %d" % err)
PY
}

fresh_file() { # 8 MiB of written random data, the model a copy
    rm -f "$F"
    head -c $((8 << 20)) /dev/urandom >"$MODEL"
    dd if="$MODEL" of="$F" bs=1M oflag=direct status=none
    sync
}

# ------------------------------------------------------------------- 1
log "1: an unaligned range over written data is zeroed in place"
fresh_file
L0="$(layout)"
[ -n "$L0" ] || { fail "1 setup: filefrag shows no extent for the written file"; ct_exit; }
Z0="$(info zero_inplace_blocks)"
OFF=$(((1 << 20) + 100)); LEN=$((3 << 20))
if fallocate -z -n -o $OFF -l $LEN "$F" 2>"$ERR"; then
    model_zero $OFF $LEN
    check 1
    WHOLE=$((((OFF + LEN) / 4096) - ((OFF + 4095) / 4096)))
    [ $(($(info zero_inplace_blocks) - Z0)) = "$WHOLE" ] &&
        pass "1: the device zeroed exactly the range's $WHOLE whole blocks" ||
        fail "1: zero_inplace_blocks moved by $(($(info zero_inplace_blocks) - Z0)), want $WHOLE"
    [ "$(layout)" = "$L0" ] && pass "1: the physical layout is unchanged ($(wc -l <<<"$L0") extent(s))" ||
        fail "1: the layout changed: $(wc -l <<<"$L0") -> $(layout | wc -l) extent(s)"
    remount
    check "1 after remount"
else
    fail "1: ZERO_RANGE failed: $(cat "$ERR")"
fi

# ------------------------------------------------------------------- 2
log "2: dirty data inside the range is not written back over the zeros"
fresh_file
OFF=$((2 << 20)); LEN=$((1 << 20))
# Dirty in the page cache when the zeroing runs; written back at close.
R="$(open_write_zero $OFF $LEN 0)"
[ "$R" = ok ] || fail "2: $R"
model_zero $OFF $LEN
check "2 before remount"
sync
remount
check 2

# ------------------------------------------------------------------- 3
log "3: a store through a shared mapping does not survive the zeroing"
fresh_file
OFF=$((4 << 20)); LEN=$((64 << 10))
R="$(python3 -I - "$F" $OFF $LEN <<'PY'
import mmap, os, subprocess, sys
f, off, ln = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fd = os.open(f, os.O_RDWR)
m = mmap.mmap(fd, 8 << 20)
m[off:off + ln] = b"\xa5" * ln      # dirty, mapped writable, no fault left to take
r = subprocess.run(["fallocate", "-z", "-n", "-o", str(off), "-l", str(ln), f], capture_output=True)
if r.returncode:
    print("fallocate failed: " + r.stderr.decode().strip()); sys.exit()
print("ok" if m[off:off + ln] == bytes(ln) else "the mapping still reads the store")
m.close(); os.close(fd)
PY
)"
[ "$R" = ok ] && pass "3: the mapping reads the zeros" || fail "3: $R"
model_zero $OFF $LEN
sync
remount
check 3

# ------------------------------------------------------------------- 4
log "4: a pending conversion is not published over the zeros"
fresh_file
fallocate -n -o $((8 << 20)) -l $((4 << 20)) "$F"
truncate -s $((12 << 20)) "$F"
python3 -I -c 'import sys; open(sys.argv[1], "ab").write(bytes(4 << 20))' "$MODEL"
OFF=$((9 << 20)); LEN=$((1 << 20))
# Into preallocated space and on to the device, the conversion pending
# until the close that follows the zeroing.
R="$(open_write_zero $OFF $LEN 1)"
[ "$R" = ok ] || fail "4: $R"
model_zero $OFF $LEN
check "4 before remount"
sync
remount
check 4

# ------------------------------------------------------------------- 5
log "5: written, preallocated, hole and past EOF in one range"
fresh_file
fallocate -n -o $((8 << 20)) -l $((1 << 20)) "$F"
truncate -s $((12 << 20)) "$F"
python3 -I -c 'import sys; open(sys.argv[1], "ab").write(bytes(4 << 20))' "$MODEL"
OFF=$((7 << 20)); LEN=$((7 << 20))
B0="$(stat -c %b "$F")"
if fallocate -z -o $OFF -l $LEN "$F" 2>"$ERR"; then
    model_zero $OFF $LEN extend
    check 5
    [ "$(stat -c %s "$F")" = $((OFF + LEN)) ] && pass "5: the size grew to the range's end" ||
        fail "5: size $(stat -c %s "$F"), want $((OFF + LEN))"
    # 8 MiB written + 1 MiB preallocated before; the range adds 3 MiB of
    # hole and 2 MiB past EOF: 14 MiB allocated, 28672 sectors.
    [ "$(stat -c %b "$F")" -ge 28672 ] && pass "5: the whole range is allocated ($(($(stat -c %b "$F") / 8)) blocks)" ||
        fail "5: $(($(stat -c %b "$F") / 8)) blocks allocated (was $((B0 / 8))), want >= 3584"
else
    fail "5: ZERO_RANGE failed: $(cat "$ERR")"
fi

# ------------------------------------------------------------------- 6
log "6: NEGATIVE CONTROL -- the old path reallocates, and the layout check sees it"
fresh_file
L0="$(layout)"
ct_param_set zero_inplace_off 1
fallocate -z -n -o $(((1 << 20) + 100)) -l $((3 << 20)) "$F" 2>"$ERR" || fail "6: ZERO_RANGE failed: $(cat "$ERR")"
ct_param_set zero_inplace_off 0
[ "$(layout)" != "$L0" ] && pass "6: punch + preallocation changed the layout ($(wc -l <<<"$L0") -> $(layout | wc -l) extent(s))" ||
    fail "6: the old path left the layout identical -- 1's layout check proves nothing"

# ------------------------------------------------------------------- 7
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "7: fsck clean" || fail "7: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
