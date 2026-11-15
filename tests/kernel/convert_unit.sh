#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# first writes into preallocated space mark a whole aligned unit written, zeroed, and never over a write in flight
#
# Each first write into a preallocated extent split it, per 4 KiB block:
# scattered first writes reached the per-file extent ceiling (258,064)
# after about a GiB of scatter, and the guest paused on ENOSPC with the
# volume free (audit 2026-11-15 A-1, G-1). A convert now marks the
# aligned 64 KiB unit around the write written, the unit's other blocks
# zeroed on the device first -- unless one of them is a block another
# write is putting data into.
#
# The preallocated blocks are filled with 0xAA on the device first, so a
# block nobody zeroed reads 0xAA there.
#   D. O_DIRECT, every other block of a 1,024-block preallocated file:
#      at most one extent per unit, 64 (not ~1,000); every written block reads back,
#      every other block reads zeros (zeroed, not the device's 0xAA);
#   B. the same buffered, then fsync: at most 64 extents, same reads;
#   R. two async O_DIRECT writes into one unit: A's completion held back
#      (dio_end_io_stall_ms) while B's completes and converts; A's data
#      survives -- B's convert saw A in flight and did not zero its block.
#
# DISCRIMINATION: convert_unit_blocks=1 (a block at a time): D and B leave
# ~1,000 extents. dio_track_off=1 (in-flight writes not tracked): R zeroes
# A's landed data.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in convert_unit_blocks dio_track_off dio_end_io_stall_ms; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
AIO="$(ct_helper dio_aio)"
MNT="$(ct_mnt cvu)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set convert_unit_blocks 16
ct_param_set dio_track_off 0
ct_param_set dio_end_io_stall_ms 0
P=/sys/module/cetrafs/parameters

fresh() { # <tag>: a fresh volume, mounted
    DEV="$(ct_loop "$(ct_image 560 "cvu$1")")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
}
# <file>: write 0xAA straight to the device under every block the file has
# preallocated, so a block nobody zeroed reads 0xAA, not the image's zeros
poison() {
    sync "$1"
    local ext
    ext="$(filefrag -v -b4096 "$1" | awk -F'[:. ]+' '/unwritten/ { print $5 "-" $6 }')"
    python3 -I - "$DEV" $ext <<'PY'
import os, sys, mmap
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
m = mmap.mmap(-1, 1 << 20); m.write(b"\xaa" * (1 << 20))
tot = 0
for r in sys.argv[2:]:
    a, b = (int(x) for x in r.split("-"))
    off, end = a * 4096, (b + 1) * 4096
    while off < end:
        n = min(1 << 20, end - off)
        os.pwritev(fd, [memoryview(m)[:n]], off)
        off += n
    tot += b + 1 - a
os.close(fd)
print(tot)
PY
}
extents() { filefrag -v "$1" | grep -cE "^ *[0-9]+:"; }
# <file>: every even block 'x', every odd block zeros -> count of blocks that are not
verify() {
    python3 -I - "$1" <<'PY'
import os, sys, mmap
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
m = mmap.mmap(-1, 4096)
bad = aa = 0
for b in range(1024):
    m.seek(0)
    os.preadv(fd, [m], b * 4096)
    want = b"x" * 4096 if b % 2 == 0 else b"\0" * 4096
    if m[:] != want:
        bad += 1
        aa += m[:] == b"\xaa" * 4096
os.close(fd)
print("bad=%d aa=%d" % (bad, aa))
PY
}

# <unit> <dio|buf> -> "extents=<n> bad=<n> aa=<n> widened=<n>"
round() {
    local proc w0 w1 out pz
    fresh "$1$2"
    proc="$(ct_procdir "$DEV")"
    echo "$1" >$P/convert_unit_blocks
    fallocate -l $((1024 * 4096)) "$MNT/f"
    pz="$(poison "$MNT/f")"
    w0="$(sed -n 's/^convert_units_widened: //p' "$proc/info")"
    python3 -I - "$MNT/f" "$2" <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096); m.write(b"x" * 4096)
flags = os.O_RDWR | (os.O_DIRECT if sys.argv[2] == "dio" else 0)
fd = os.open(sys.argv[1], flags)
for b in range(0, 1024, 2):
    os.pwrite(fd, m, b * 4096)
os.fsync(fd); os.close(fd)
PY
    w1="$(sed -n 's/^convert_units_widened: //p' "$proc/info")"
    out="$(verify "$MNT/f")"
    echo "extents=$(extents "$MNT/f") $out widened=$((w1 - w0)) poisoned=$pz"
    ct_umount "$MNT"
    echo 16 >$P/convert_unit_blocks
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

for mode in dio buf; do
    R="$(round 16 "$mode")"
    log "$mode, 64 KiB units: $R"
    C="$(round 1 "$mode")"
    log "$mode, control (a block at a time): $C"
    [ "$(get poisoned "$R")" = 1024 ] && [ "$(get poisoned "$C")" = 1024 ] ||
        { fail "$mode setup: the preallocated blocks were not all poisoned ($R | $C)"; continue; }
    [ "$(get extents "$C")" -ge 500 ] || { fail "$mode setup: a block at a time left only $(get extents "$C") extents ($C)"; continue; }
    [ "$(get extents "$R")" -le 64 ] && [ "$(get bad "$R")" = 0 ] &&
        pass "$mode: $(get extents "$R") extent(s), not $(get extents "$C"); written blocks read back, the rest zeros" ||
        fail "$mode: $R"
    [ "$(get bad "$C")" = 0 ] || fail "$mode control: the block-at-a-time reads are wrong too ($C)"
done

# R <track_off 0|1> -> "a=<c> b=<c> a_inflight=<0|1>"
race() {
    local out
    fresh "race$1"
    fallocate -l $((1024 * 4096)) "$MNT/g"
    echo "$1" >$P/dio_track_off
    echo 1500 >$P/dio_end_io_stall_ms
    out="$("$AIO" unit "$MNT/g" 3 9 200)"
    echo 0 >$P/dio_end_io_stall_ms
    echo 0 >$P/dio_track_off
    ct_umount "$MNT"
    echo "$out"
}
R="$(race 0)"
log "race, tracked: $R"
C="$(race 1)"
log "race, control (untracked): $C"
[ "$(get a_inflight "$R")" = 1 ] && [ "$(get a_inflight "$C")" = 1 ] ||
    { fail "R setup: A had completed before B -- the stall did not hold its completion ($R | $C)"; ct_exit; }
[ "$(get a "$R")" = A ] && [ "$(get b "$R")" = B ] && pass "R: A's landed write survived B's unit convert" ||
    fail "R: tracked: $R"
[ "$(get a "$C")" = 0 ] && pass "R control: untracked, B's unit convert zeroed A's landed data" ||
    fail "R control: untracked, A's block reads $(get a "$C") -- the race was not reached"
ct_exit
