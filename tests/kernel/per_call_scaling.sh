#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a per-call operation on a fragmented file costs the same at N and 4N extents
#
# Per-call cost that grows with the file was invisible to every suite:
# fiemap re-read and re-sorted a 258k-extent tree per call (b6bc3ce), and
# SEEK_HOLE was O(n^2). For each operation that holds the inode lock, this
# runs it on a depth-2 file of N and of 4N one-block extents and compares
# the device reads and sorted-map rebuilds per call, through one open, after a first call has
# warmed the cache (the first read after an open is fresh by design, and
# is once per open, not per call):
#   fiemap (one 64-extent window), SEEK_DATA/SEEK_HOLE, a 4 KiB write into
#   a hole, an overwrite, a punch of one block, fallocate of one block,
#   truncate by one block, fsync after an overwrite.
# Each must not grow with N: at 4N it reads at most its N cost plus a
# small constant (a deeper path through one more index block).
#
# The control for the instrument: SEEK_HOLE with read_trust_off (the
# readers' pre-fix behaviour, which reads the tree per call) must be
# caught growing, so a flat result means something.
#
# Under nofilelock the reader-trust control does not reach a sole
# opener's tree (see fiemap_reader_cache.sh): the control is skipped there.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/read_trust_off ] || { skip "read_trust_off is missing"; ct_exit; }

N=2000
CALLS=20
SLACK=4 # reads per call a 4N file may add: one more interior/leaf on the path
MNT="$(ct_mnt scal)"
ct_track mnt "$MNT"
OPS="fiemap seek hole_write overwrite punch falloc truncate fsync"

PROBE="$(ct_tmp scal-probe.py)"
cat >"$PROBE" <<'PY'
import ctypes, fcntl, os, struct, sys
path, op, n, calls, stat, info = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
libc = ctypes.CDLL(None, use_errno=True)
def reads():
    return int(open(stat).read().split()[0])
def builds():
    for l in open(info):
        if l.startswith("smap_builds: "):
            return int(l.split()[1])
    return 0
# The reporting calls only read the map: open as a reader does, which is
# what the reader-trust rule (and its control) is about.
fd = os.open(path, os.O_RDONLY if op in ("fiemap", "seek") else os.O_RDWR)
SEEK_DATA, SEEK_HOLE = 3, 4
def one(i):
    blk = 2 * ((i * 7919) % n)          # a written block, spread over the file
    if op == "fiemap":
        hdr = struct.pack("QQIIII", blk * 4096, 2**64 - 1, 0, 0, 64, 0)
        fcntl.ioctl(fd, 0xC020660B, bytearray(hdr + bytes(56 * 64)))
    elif op == "seek":
        os.lseek(fd, blk * 4096, SEEK_HOLE); os.lseek(fd, (blk + 1) * 4096, SEEK_DATA)
    elif op == "hole_write":
        os.pwrite(fd, b"h" * 4096, (blk + 1) * 4096)
    elif op == "overwrite":
        os.pwrite(fd, b"o" * 4096, blk * 4096)
    elif op == "punch":
        libc.fallocate(fd, 0x03, ctypes.c_long(blk * 4096), ctypes.c_long(4096))
    elif op == "falloc":
        libc.fallocate(fd, 0x01, ctypes.c_long((blk + 1) * 4096), ctypes.c_long(4096))
    elif op == "truncate":
        os.ftruncate(fd, os.fstat(fd).st_size - 4096)
    elif op == "fsync":
        os.pwrite(fd, b"s" * 4096, blk * 4096); os.fsync(fd)
one(calls)                               # warm: the open's first fresh read
r0, b0 = reads(), builds()
for i in range(calls):
    one(i)
print((reads() - r0) / calls, (builds() - b0) / calls)
os.close(fd)
PY

# <extents> <op> [knob] -> "<reads per call> <map rebuilds per call>"
measure() {
    local dev loop out
    dev="$(ct_loop "$(ct_image 1200 "scal$1$2")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    ct_param_set auto_defrag 0
    loop="$(basename "$dev")"
    python3 - "$MNT/f" "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(int(sys.argv[2])):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
    sync
    [ -n "${3:-}" ] && ct_param_set "$3" 1
    out="$(python3 "$PROBE" "$MNT/f" "$2" "$1" "$CALLS" "/sys/block/$loop/stat" "$(ct_procdir "$dev")/info")"
    [ -n "${3:-}" ] && ct_param_set "$3" 0
    ct_umount "$MNT"
    set -- $out
    printf '%.0f %.0f\n' "$1" "$2"
}

for op in $OPS; do
    read -r a am <<<"$(measure $N $op)"
    read -r b bm <<<"$(measure $((4 * N)) $op)"
    log "$op: $a reads and $am map rebuilds per call at $N extents, $b and $bm at $((4 * N))"
    [ "$b" -le $((a + SLACK)) ] && [ "$bm" -le "$am" ] &&
        pass "$op: per-call reads and map rebuilds do not grow with the file ($a -> $b, $am -> $bm)" ||
        fail "$op: per-call cost grows with the file: reads $a -> $b, map rebuilds $am -> $bm"
done

if ct_nofilelock_run; then
    skip "control: read_trust_off does not reach a sole opener's tree under nofilelock"
else
    read -r a _ <<<"$(measure $N seek read_trust_off)"
    read -r b _ <<<"$(measure $((4 * N)) seek read_trust_off)"
    log "control (read_trust_off) seek: $a reads/call at $N extents, $b at $((4 * N))"
    [ "$b" -gt $((a + SLACK)) ] && pass "control: a reader that reads its tree per call is caught growing ($a -> $b)" ||
        fail "control: read_trust_off gave $a -> $b -- the instrument cannot see growth"
fi
ct_exit
