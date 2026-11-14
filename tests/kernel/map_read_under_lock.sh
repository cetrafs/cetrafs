#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SEEK_DATA and FIEMAP read the record under invalidate_lock, not before it
#
# A convert that splits a full extent leaf publishes a new root inside its
# exclusive hold of invalidate_lock. SEEK_HOLE/SEEK_DATA and FIEMAP used to
# read the record BEFORE taking that lock, so a walk could pair a record
# from before the convert with leaves from after it (audit 2026-11-14
# FD-4). The record is now read under the lock, as the lookup path does.
#
# What this suite checks, on a real mount:
#   1. a FIEMAP held in a window (map_read_pause_ms, between its record
#      read and its walk) while a page-fault convert of a block in the
#      same full leaf is requested reports every written block the leaf
#      held before the convert -- the convert waits for the walk;
#   2. the same window for SEEK_DATA gives the answer the pre-convert map
#      holds.
#
# NOT DISCRIMINATED on a loop device: map_read_late restores the old
# order, but with this leaf geometry the converted leaf came back intact
# to the stale walk, so the control reads the same map as the fix. The
# control is run and its numbers logged, not asserted, so this suite does
# not claim a guard it cannot show. The window is still the instrument
# for the two-node rig (ctest/), where a peer's convert is real.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in map_read_late map_read_pause_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt mrul)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
ct_param_set map_read_late 0
ct_param_set map_read_pause_ms 0
RACE="$(ct_tmp mrul-race.py)"
cat >"$RACE" <<'PY'
import fcntl, mmap, os, struct, sys, threading, time
path, mode, pause_knob = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(path, os.O_RDWR)
Z = 1000
os.pwrite(fd, b"Z" * 4096, Z * 4096)
os.fsync(fd)
# Writes with an fsync each, up to 253 extents (no FIEMAP here: a FIEMAP
# caches the sorted map and would mask the walk). 3 + 2 * 125 = 253.
i = 1
while i < 126:
    os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
    os.fsync(fd)
    i += 1
blk = 2 * i * 4096  # uninit: converted by the page fault below
written = [2 * k for k in range(1, i)] + [Z]
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
mm = mmap.mmap(fd, 4 * 1024 * 1024, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
NEXT = 512
result = {}
def fiemap_all():
    open(pause_knob, "w").write("1500")
    buf = bytearray(struct.pack("QQIIII", 0, 4 * 1024 * 1024, 0, 0, NEXT, 0) + bytes(NEXT * 56))
    fcntl.ioctl(fd, 0xC020660B, buf)
    mapped = struct.unpack_from("I", buf, 20)[0]
    covered = set()
    for k in range(mapped):
        logical, _phys, length = struct.unpack_from("QQQ", buf, 32 + 56 * k)
        covered.update(range(logical // 4096, (logical + length) // 4096))
    result["mapped"] = mapped
    result["missing"] = [b for b in written if b not in covered]
def seek_all():
    open(pause_knob, "w").write("1500")
    result["seek"] = os.lseek(fd, Z * 4096, os.SEEK_DATA)
probe = fiemap_all if mode == "fiemap" else seek_all
t = threading.Thread(target=probe)
t.start()
time.sleep(0.4)
mm[blk] = 0x5A  # page_mkwrite converts blk through the full leaf
t.join()
mm.close()
open(pause_knob, "w").write("0")
os.close(fd)
if mode == "fiemap":
    print(i, len(written), result["mapped"], len(result["missing"]), flush=True)
else:
    print(i, len(written), result["seek"] == Z * 4096, result["seek"], flush=True)
PY

# <mode> <late 0|1> -> fiemap: "<i> <written> <runs> <missing>"; seek: "<i> <written> <ok> <answer>"
probe() {
    local dev out
    dev="$(ct_loop "$(ct_image 560 "mrul$1$2")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$2" >$P/map_read_late
    fallocate -l 4M "$MNT/f"
    out="$(python3 "$RACE" "$MNT/f" "$1" $P/map_read_pause_ms)"
    echo 0 >$P/map_read_late
    ct_umount "$MNT"
    echo "$out"
}

read -r I W RUNS MISS <<<"$(probe fiemap 0)"
log "fixed fiemap: $I, $W written block(s) in the leaf, $RUNS run(s) reported, $MISS missing"
[ "$RUNS" = 253 ] || fail "setup: the walk saw $RUNS run(s), not the 253 the leaf held before the convert"
[ "$MISS" = 0 ] && pass "1: a FIEMAP walked during a convert reports every written block of the pre-convert map" ||
    fail "1: $MISS written block(s) missing from the FIEMAP walked during a convert"
read -r I W OK ANS <<<"$(probe seek 0)"
log "fixed seek: block $((ANS / 4096)) answered $ANS, ok=$OK"
[ "$OK" = True ] && pass "2: SEEK_DATA during a convert answers the written block" ||
    fail "2: SEEK_DATA answered $ANS for the written block at $((4096000 / 4096)) -- the map and the leaves disagree"
read -r I W RUNS MISS <<<"$(probe fiemap 1)"
log "control fiemap (old order): $RUNS run(s), $MISS missing -- logged, not asserted (see header)"
ct_exit
