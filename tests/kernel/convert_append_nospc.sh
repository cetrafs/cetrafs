#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a convert that cannot grow the tree fails with nothing edited, and its block stays pending
#
# Marking a preallocated block written in a full extent leaf splits the
# extent: the leaf is shrunk so it no longer covers the block, and the
# block is appended through the tree, which may need a new leaf. On a
# full volume that append failed AFTER the shrink: the block was in no
# extent, its data on the device, the first fsync said ENOSPC and the
# next one found a "hole", called it nothing left to convert and
# succeeded -- the file reads zeros there for good (audit 2026-11-14
# FD-1). The append's blocks are now reserved before the shrink, and a
# pending block that maps to a hole is reported, never cleared.
#
# A preallocated file is written every other block, fsync after each:
# each write splits the preallocated extent around it, two more entries
# in the one external leaf (254 slots), until the leaf holds 253. The
# next write's split then needs two slots and has one, so its block goes
# through the tree, which must grow a leaf. With convert_append_nospc
# the tree blocks for that append fail ENOSPC:
#   1. that fsync fails;
#   2. with space back, the next fsync converts and succeeds;
#   3. after a remount every written block reads back.
#
# DISCRIMINATION: tree_resv_off shrinks before reserving, as before; 3
# must then find the last block reading zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in convert_append_nospc tree_resv_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt cans)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set convert_append_nospc 0
ct_param_set tree_resv_off 0
P=/sys/module/cetrafs/parameters
WRITER="$(ct_tmp cans-writer.py)"
READER="$(ct_tmp cans-reader.py)"
cat >"$WRITER" <<'PY'
import fcntl, os, struct, sys
path, knob = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR)
def extents():
    buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, 0, 0))
    fcntl.ioctl(fd, 0xC020660B, buf)
    return struct.unpack("QQIIII", bytes(buf))[3]
def sync():
    try:
        os.fsync(fd)
        return "ok"
    except OSError as e:
        return e.strerror.replace(" ", "_")
i = 1
while extents() < 253 and i < 400:
    os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
    os.fsync(fd)
    i += 1
n = extents()
os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
open(knob, "w").write("1")
a = sync()
open(knob, "w").write("0")
b = sync()
try:
    os.close(fd)
except OSError:
    pass
print(a, b, n, i, flush=True)
PY
cat >"$READER" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = 0
for i in range(1, int(sys.argv[2]) + 1):
    bad += sum(1 for x in os.pread(fd, 4096, 2 * i * 4096) if x != 65 + i % 26)
print(bad, flush=True)
PY

# <tree_resv_off 0|1> -> "<fsync 1> <fsync 2> <bad bytes after remount> <extents before the last write>"
probe() {
    local dev a b n i bad
    dev="$(ct_loop "$(ct_image 560 "cans$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/tree_resv_off
    fallocate -l 4M "$MNT/f"
    read -r a b n i <<<"$(python3 "$WRITER" "$MNT/f" $P/convert_append_nospc)"
    echo 0 >$P/tree_resv_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    ct_mount "$dev" "$MNT"
    bad="$(python3 "$READER" "$MNT/f" "$i")"
    ct_umount "$MNT"
    echo "$a $b $bad $n"
}

read -r A B BAD N <<<"$(probe 0)"
log "fixed: fsync $A then $B, $BAD bad byte(s) after remount, $N extent(s) before the last write"
[ "$N" = 253 ] || fail "setup: the leaf holds $N extents before the last write, not 253 -- its split does not need the tree"
[ "$A" != ok ] && pass "1: the fsync whose append found no space fails ($A)" ||
    fail "1: the fsync succeeded with no space for the append"
[ "$B" = ok ] && pass "2: with space back the next fsync converts the block" ||
    fail "2: the fsync with space back failed: $B"
[ "$BAD" = 0 ] && pass "3: after a remount every written block reads back" ||
    fail "3: $BAD byte(s) read back wrong -- the block left the map"
read -r A0 B0 BAD0 N0 <<<"$(probe 1)"
log "control: fsync $A0 then $B0, $BAD0 bad byte(s) after remount"
[ "${BAD0:-0}" -gt 0 ] && pass "control: shrinking before reserving loses the block ($BAD0 bad bytes) -- the suite discriminates" ||
    fail "control: tree_resv_off kept the block too -- the suite cannot tell"
ct_exit
