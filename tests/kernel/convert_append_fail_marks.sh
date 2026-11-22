#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a convert that loses its block after shrinking a full leaf marks the file damaged
#
# Converting a written preallocated block in a full extent leaf shrinks
# the leaf -- held back, possibly on the device already -- and appends
# the block through the tree. Only ENOSPC from that append was handled
# (a stop: the room was reserved). Any other error left the block, and
# the preallocated tail after it, in no extent, the record the caller
# then dropped still counting them, and a warning that "no data is
# lost" -- though a pending convert runs at the fsync, after the write
# was acknowledged, so what was written there now reads as a hole
# (audit 2026-11-22 N-3). Such a file is now marked damaged, as a split
# that could not finish is.
#
# The leaf is filled as in convert_append_nospc.sh (a preallocated file
# written every other block, fsync after each, until the one leaf holds
# 253 entries); the next write's split must go through the tree, and
# convert_append_fail_once fails that append -EIO:
#   1. that fsync fails;
#   2. the file is marked damaged: the corruption count moves, and a
#      write to it is refused (EUCLEAN).
#
# DISCRIMINATION: the control, in-suite -- convert_fail_unmarked=1: the
# same failure leaves the file unmarked -- nothing counted, and its
# writes not refused as damage.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in convert_append_fail_once convert_fail_unmarked; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt cafm)"
ct_track mnt "$MNT"
ct_param_set convert_unit_blocks 1
ct_param_set auto_defrag 0
ct_param_set convert_append_fail_once 0
ct_param_set convert_fail_unmarked 0
WRITER="$(ct_tmp cafm-writer.py)"
cat >"$WRITER" <<'PY'
import errno, fcntl, os, struct, sys
path, knob = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR)
def extents():
    buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, 0, 0))
    fcntl.ioctl(fd, 0xC020660B, buf)
    return struct.unpack("QQIIII", bytes(buf))[3]
def tryit(f):
    try:
        f()
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
i = 1
while extents() < 253 and i < 400:
    os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
    os.fsync(fd)
    i += 1
n = extents()
os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
open(knob, "w").write("1")
a = tryit(lambda: os.fsync(fd))
open(knob, "w").write("0")
b = tryit(lambda: (os.pwrite(fd, b"z" * 4096, 0), os.fsync(fd)))
try:
    os.close(fd)
except OSError:
    pass
print(a, b, n, flush=True)
PY

# <unmarked 0|1> -> "<fsync> <later write> <extents before> <corruptions moved>"
probe() {
    local dev proc a b n c0 c1
    dev="$(ct_loop "$(ct_image 560 "cafm$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "$1" >$P/convert_fail_unmarked
    fallocate -l 4M "$MNT/f"
    c0="$(sed -n 's/^corruptions: //p' "$proc/info")"
    read -r a b n <<<"$(python3 "$WRITER" "$MNT/f" $P/convert_append_fail_once)"
    c1="$(sed -n 's/^corruptions: //p' "$proc/info")"
    echo 0 >$P/convert_fail_unmarked
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo "$a $b $n $((c1 - c0))"
}

read -r A0 B0 N0 C0 <<<"$(probe 1)"
log "control: fsync $A0, later write $B0, $N0 extents before, corruptions +$C0"
read -r A B N C <<<"$(probe 0)"
log "fixed: fsync $A, later write $B, $N extents before, corruptions +$C"
[ "$N" = 253 ] && [ "$N0" = 253 ] ||
    { fail "setup: the leaf holds $N / $N0 extents before the last write, not 253 -- its split does not need the tree"; ct_exit; }
[ "$A0" != ok ] && [ "$C0" = 0 ] && [ "$B0" != EUCLEAN ] &&
    pass "control: unmarked, the file with a block in no extent is not counted damaged (later write: $B0)" ||
    fail "control: the hazard did not reproduce -- fsync $A0, later write $B0, corruptions +$C0"
[ "$A" != ok ] && pass "1: the fsync whose append failed fails ($A)" || fail "1: the fsync succeeded"
[ "$C" -ge 1 ] && [ "$B" = EUCLEAN ] && pass "2: the file is marked damaged: counted (+$C), a later write refused ($B)" ||
    fail "2: corruptions +$C, later write $B"
ct_exit
