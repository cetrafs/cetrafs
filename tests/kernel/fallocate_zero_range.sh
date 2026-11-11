#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate(ZERO_RANGE) zeroes exactly its range, allocates it, and moves the size only without KEEP_SIZE
#
# ZERO_RANGE returned EOPNOTSUPP, so qemu's write-zeroes wrote real
# zeroes through the data path. It is now a punch followed by a
# preallocation of the same range (cetrafs_fallocate()). Each case is
# checked byte for byte against a model of the file, through the page
# cache and with O_DIRECT, and the range must end up ALLOCATED (that is
# what separates it from a punch):
#
#  1. data file, unaligned range inside it, KEEP_SIZE: the range reads
#     zero, every other byte is unchanged, the size is unchanged.
#  2. a range straddling EOF without KEEP_SIZE: the size grows to its
#     end, the new tail reads zero.
#  3. a range over a hole: it is allocated afterwards, and reads zero.
#  4. fsck is clean after unmount.
#
# DISCRIMINATION (2026-11-11, file.c before this change): 1 fails with
# "Operation not supported".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fallocate >/dev/null || { skip "no fallocate(1)"; ct_exit; }

DEV="$(ct_dev 560 zrange)"
MNT="$(ct_mnt zrange)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
F="$MNT/img"
MODEL="$(ct_tmp zrmodel)"
ERR="$(ct_tmp zrerr)"

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
n = os.readv(fd, [buf]); os.close(fd)
if bytes(buf[:size]) != want:
    print("O_DIRECT: differs from the model"); sys.exit()
print("ok")
PY
)"
    [ "$r" = ok ] && pass "$c: every byte matches the model (buffered and O_DIRECT)" || fail "$c: $r"
}
# model_zero <off> <len> [extend]: zero the model's range, growing it if asked.
model_zero() {
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
blocks() { stat -c %b "$F"; }

head -c $((4 << 20)) /dev/urandom >"$MODEL"
cp "$MODEL" "$F"
sync

log "1: unaligned range inside the data, KEEP_SIZE"
OFF=100001; LEN=$((1 << 20))
S0="$(stat -c %s "$F")"
if fallocate -z -n -o $OFF -l $LEN "$F" 2>"$ERR"; then
    model_zero $OFF $LEN
    check 1
    [ "$(stat -c %s "$F")" = "$S0" ] && pass "1: the size is unchanged" || fail "1: KEEP_SIZE moved the size to $(stat -c %s "$F")"
else
    fail "1: ZERO_RANGE failed: $(cat "$ERR")"
fi

log "2: a range straddling EOF, no KEEP_SIZE"
S0="$(stat -c %s "$F")"
OFF=$((S0 - 1000)); LEN=$((64 << 10))
if fallocate -z -o $OFF -l $LEN "$F" 2>"$ERR"; then
    model_zero $OFF $LEN extend
    check 2
    [ "$(stat -c %s "$F")" = $((OFF + LEN)) ] && pass "2: the size grew to the range's end" ||
        fail "2: size $(stat -c %s "$F"), want $((OFF + LEN))"
else
    fail "2: ZERO_RANGE failed: $(cat "$ERR")"
fi

log "3: a range over a hole is allocated"
S0="$(stat -c %s "$F")"
truncate -s $((S0 + (8 << 20))) "$F"
python3 -I -c 'import sys; open(sys.argv[1], "ab").write(bytes(8 << 20))' "$MODEL"
OFF=$((S0 + (2 << 20))); LEN=$((2 << 20))
B0="$(blocks)"
if fallocate -z -n -o $OFF -l $LEN "$F" 2>"$ERR"; then
    B1="$(blocks)"
    # st_blocks is in 512-byte units: the range's 2 MiB is 4096 of them.
    [ $((B1 - B0)) -ge 4096 ] && pass "3: the hole was allocated ($(((B1 - B0) / 8)) blocks)" ||
        fail "3: only $(((B1 - B0) / 8)) blocks were allocated for a 512-block range"
    check 3
else
    fail "3: ZERO_RANGE failed: $(cat "$ERR")"
fi

ct_umount "$MNT"
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 && pass "4: fsck is clean" || fail "4: fsck reports problems"
ct_exit
