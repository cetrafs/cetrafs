#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a buffered write's extent never reaches the device marked written before its data
#
# A buffered write's data sits in the file's page cache; the extent edit
# that maps it sits in a block-device buffer (a leaf, for a file past
# four extents). Two writeback queues, no order between them. When the
# write marked its block written at once, the leaf could reach the
# platter first -- and a crash in that gap left the file reading
# whatever the block held before: another file's deleted data (audit
# R12). Now a buffered write maps its blocks preallocated and marks them
# written only at fsync/close/sync, after the data is down.
#
# Staged with the crash rig: the data volume is pre-filled with a marker,
# so any block mapped as data that never got its data reads as the
# marker. A depth-1 file (seven extents) gets one buffered write into a
# preallocated block and one into a hole inside i_size; then the BLOCK
# DEVICE is fsync'd -- every dirty metadata buffer written, the file's
# pages not -- and the power is "cut" there (a dm-log-writes mark). A
# replay to the cut must read zeros or the new data, never the marker;
# a replay past the file's fsync must read the new data.
#
# DISCRIMINATION: built in. The first round records with
# buf_convert_early=1 (blocks marked written at write time, as before)
# and must read the marker at the cut -- proving the recording really
# arranged leaf-before-data. The second round, the fix, must not.
#
# Opt-in like the rest of tests/crash (make check-crash).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/buf_convert_early ] || { skip "buf_convert_early is missing"; ct_exit; }

REPLAY="$CT_BUILD/replay-log"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi
ct_param_set hb_interval_secs 1 # a replayed image's mount watches its row (see crash_consistency.sh)
ct_param_set stale_secs 4

SZ_MB=560
SECTORS=$((SZ_MB * 1024 * 1024 / 512))
MNT="$(ct_mnt bufext)"
ct_track mnt "$MNT"

# fill <file-or-dev>: the marker, over every byte.
fill() {
    python3 - "$1" "$SZ_MB" <<'PY'
import sys
chunk = b"STALEDAT" * (1 << 17)  # 1 MiB
with open(sys.argv[1], "r+b") as f:
    for _ in range(int(sys.argv[2])):
        f.write(chunk)
PY
}

# read_blk <blk>: what block <blk> of $MNT/vm holds -- NEW, HOLE, ZERO, STALE or OTHER.
read_blk() {
    python3 - "$MNT/vm" "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
b = os.pread(fd, 4096, int(sys.argv[2]) * 4096)
os.close(fd)
if b == b"N" * 4096: print("NEW")
elif b == b"H" * 4096: print("HOLE")
elif b == bytes(4096): print("ZERO")
elif b"STALEDAT" in b: print("STALE")
else: print("OTHER")
PY
}

# round <early>: record the workload, then replay to the cut and past
# the fsync. Prints "<blk100-at-cut> <blk200-at-cut> <blk100-synced> <blk200-synced>".
round() {
    local early="$1" data log rimg dm lw r100 r200 s100 s200
    data="$(ct_image "$SZ_MB" "bufext-d$early")"
    log="$(ct_image 512 "bufext-l$early")"
    rimg="$(ct_image "$SZ_MB" "bufext-r$early")"
    fill "$data"
    data="$(ct_loop "$data")"
    log="$(ct_loop "$log")"
    dm="bufext_${early}_$$"
    dmsetup create "$dm" --table "0 $SECTORS log-writes $data $log"
    ct_track dm "$dm"
    lw="/dev/mapper/$dm"

    ct_param_set buf_convert_early "$early"
    ct_mkfs "$lw" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$lw" "$MNT"
    python3 - "$MNT/vm" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
for i in range(6):                       # six extents: past the four inline slots
    os.pwrite(fd, b"D" * 4096, i * 2 * 4096)
os.posix_fallocate(fd, 64 * 4096, 64 * 4096)   # blocks 64..127 preallocated
os.ftruncate(fd, 256 * 4096)                   # 128..255 a hole inside i_size
os.fsync(fd)
os.close(fd)
PY
    sync
    python3 - "$MNT/vm" "$lw" "$dm" <<'PY'
import os, subprocess, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b"N" * 4096, 100 * 4096)   # into the preallocation
os.pwrite(fd, b"H" * 4096, 200 * 4096)   # into the hole
b = os.open(sys.argv[2], os.O_RDONLY)    # the metadata, not the file's pages
os.fsync(b)
os.close(b)
subprocess.run(["dmsetup", "message", sys.argv[3], "0", "mark", "cut"], check=True)
os.fsync(fd)
subprocess.run(["dmsetup", "message", sys.argv[3], "0", "mark", "synced"], check=True)
os.close(fd)
PY
    ct_umount "$MNT"
    ct_param_set buf_convert_early 0
    dmsetup remove "$dm"
    blockdev --flushbufs "$log"

    rimg="$(ct_loop "$rimg")"
    fill "$rimg"
    "$REPLAY" --log "$log" --replay "$rimg" --end-mark cut 2>/dev/null
    blockdev --flushbufs "$rimg"
    mount -t cetrafs "$rimg" "$MNT" || { echo "MOUNTFAIL MOUNTFAIL - -"; return; }
    r100="$(read_blk 100)"; r200="$(read_blk 200)"
    umount "$MNT"
    fill "$rimg"
    "$REPLAY" --log "$log" --replay "$rimg" --end-mark synced 2>/dev/null
    blockdev --flushbufs "$rimg"
    mount -t cetrafs "$rimg" "$MNT" || { echo "$r100 $r200 MOUNTFAIL MOUNTFAIL"; return; }
    s100="$(read_blk 100)"; s200="$(read_blk 200)"
    umount "$MNT"
    echo "$r100 $r200 $s100 $s200"
}

read -r C100 C200 _ _ < <(round 1)
log "control (marked written at write time): at the cut block 100=$C100, block 200=$C200"
[ "$C100" = STALE ] || [ "$C200" = STALE ] &&
    pass "control: with the old order the cut exposes the previous contents -- the recording arranged leaf-before-data" ||
    { fail "setup: even the old order exposed nothing at the cut ($C100/$C200) -- this suite proves nothing"; ct_exit; }

read -r R100 R200 S100 S200 < <(round 0)
log "fixed: at the cut block 100=$R100, block 200=$R200; after fsync $S100 / $S200"
case "$R100" in NEW | ZERO) pass "preallocated block: $R100 at the cut, never the previous contents" ;;
*) fail "preallocated block read $R100 at the cut -- its extent reached the device before its data" ;; esac
case "$R200" in HOLE | ZERO) pass "hole inside i_size: $R200 at the cut, never the previous contents" ;;
*) fail "hole block read $R200 at the cut -- its extent reached the device before its data" ;; esac
[ "$S100" = NEW ] && [ "$S200" = HOLE ] && pass "after the fsync both writes are there" ||
    fail "after the fsync: block 100=$S100, block 200=$S200 -- fsync lost a buffered write"
ct_exit
