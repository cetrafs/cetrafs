#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SEEK_DATA/SEEK_HOLE and FIEMAP answer the same past the map's memory budget, one window at a time
#
# Both read a sorted copy of the whole extent map, and a depth-3 tree
# holds 65.5M extents: a fragmented image made that a GFP_NOFS kvmalloc
# of 2 GiB, cached on the inode (audit 2026-11-15 F-62). The map now has
# a budget (1M runs); past it the answer is built from windows -- the
# budget's worth of runs of lowest start past the block asked about --
# and a caller moving forward reuses a window until it walks past it.
#
# A preallocated file is written every other block in its first half
# and in scattered runs after (data, unwritten and hole extents,
# unordered in the tree), and past the preallocation 1,000 blocks are
# written top-down: contiguous data in 1,000 extents, which a SEEK_HOLE
# must cross window after window. Under the default budget the map is
# whole; SEEK_DATA and SEEK_HOLE from every 3rd block and a full fiemap
# are recorded. TEST ONLY smap_budget then shrinks the budget to 100,
# 7 and 2 runs (the floor: one run that covers the block asked about
# would leave a window nothing past it):
#   setup: the file has more extents than the largest small budget;
#   1. every SEEK answer and the whole fiemap (with its LAST flag) match
#      the whole-map answers, at each budget;
#   2. windows were built (smap_windows moved), and a forward SEEK sweep
#      reused them (smap_hits moved);
#   3. fiemap with a small buffer (filefrag's way: several calls) and
#      from an offset inside the file also match.
#
# DISCRIMINATION: smap_unbounded=1 with the budget at 100 builds the
# whole map again: no window is built. What this cannot see is the
# memory itself; the window count is the observable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/smap_budget ] || { skip "smap_budget is missing"; ct_exit; }
IMG="$(ct_image 560 smb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt smb)"
ct_track mnt "$MNT"
ct_param_set smap_budget 0
ct_param_set smap_unbounded 0
ct_mkfs "$DEV" -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

N=6000
fallocate -l $((N * 4096)) "$MNT/img"
truncate -s $(((N + 3000) * 4096)) "$MNT/img" # a tail past the preallocation
python3 -I - "$MNT/img" "$N" <<'PY'
import mmap, os, random, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
n = int(sys.argv[2])
bufs = {}
for k in range(1, 5): # page-aligned, as O_DIRECT needs: a slice is a copy
    bufs[k] = mmap.mmap(-1, 4096 * k)
    bufs[k].write(b"d" * 4096 * k)
blocks = list(range(0, n // 2, 2))
random.seed(7)
random.shuffle(blocks) # unordered in the tree
for b in blocks:
    os.pwrite(fd, bufs[1], b * 4096)
for b in range(n // 2, n - 4, 9):
    os.pwrite(fd, bufs[1 + b % 4], b * 4096)
# Past the preallocation, 1000 blocks written one at a time from the top
# down: contiguous data in 1000 extents (a descending write never merges
# with the last one), so a SEEK_HOLE from its start has to cross every
# window it spans.
for b in range(n + 1999, n + 999, -1):
    os.pwrite(fd, bufs[1], b * 4096)
os.fsync(fd)
os.close(fd)
PY

# The answers: SEEK_DATA/SEEK_HOLE from every 3rd block, then a full
# fiemap (one call, large buffer), a fiemap in calls of 17 extents, and
# one from the middle of the file. One line each, compared as text.
answers() {
    python3 -I - "$MNT/img" <<'PY'
import errno, fcntl, os, struct, sys
path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
size = os.fstat(fd).st_size
out = []
for b in range(0, size // 4096, 3):
    for w in (os.SEEK_DATA, os.SEEK_HOLE):
        try:
            out.append("%d:%d:%d" % (b, w, os.lseek(fd, b * 4096, w)))
        except OSError as e:
            out.append("%d:%d:E%d" % (b, w, e.errno))
print(" ".join(out))
FIEMAP = 0xC020660B
def fiemap(start, length, count):
    hdr = struct.pack("QQIIII", start, length, 0, 0, count, 0)
    buf = bytearray(hdr + b"\0" * (56 * count))
    fcntl.ioctl(fd, FIEMAP, buf)
    n = struct.unpack_from("QQIIII", buf)[3]
    ex = []
    for i in range(n):
        lo, ph, ln, _, _, fl = struct.unpack_from("QQQQQI", buf, 32 + 56 * i)
        ex.append((lo, ph, ln, fl))
    return ex
whole = fiemap(0, 2**64 - 1, 20000)
print(" ".join("%d,%d,%d,%x" % e for e in whole))
calls, cur = [], 0
while True:
    ex = fiemap(cur, 2**64 - 1 - cur, 17)
    calls += ex
    if not ex or ex[-1][3] & 1:
        break
    cur = ex[-1][0] + ex[-1][2]
print(" ".join("%d,%d,%d,%x" % e for e in calls))
mid = fiemap(size // 3, size // 3, 20000)
print(" ".join("%d,%d,%d,%x" % e for e in mid))
print(len(whole))
PY
}

REF="$(answers)"
NEXT="$(tail -1 <<<"$REF")"
[ "$NEXT" -gt 100 ] || { fail "setup: only $NEXT extents -- no budget below it would need a window"; ct_exit; }
[ "$(info smap_windows)" = 0 ] || { fail "setup: the default budget already built windows"; ct_exit; }
grep -q ',1$\|,[0-9a-f]*[13579bdf]$' <<<"$(sed -n 2p <<<"$REF" | tr ' ' '\n' | tail -1)" ||
    { fail "setup: the whole map's last extent is not flagged LAST"; ct_exit; }
pass "setup: $NEXT extents; whole-map answers recorded"

for B in 100 7 2; do
    ct_param_set smap_budget "$B"
    w0="$(info smap_windows)"
    h0="$(info smap_hits)"
    GOT="$(answers)"
    w1="$(info smap_windows)"
    h1="$(info smap_hits)"
    ct_param_set smap_budget 0
    if [ "$GOT" = "$REF" ]; then
        pass "1/3 (budget $B): every SEEK and fiemap answer matches the whole map"
    else
        diff <(tr ' ' '\n' <<<"$REF") <(tr ' ' '\n' <<<"$GOT") | head -6 >&2 || true
        fail "1/3 (budget $B): the windowed answers differ from the whole map"
    fi
    [ "$w1" -gt "$w0" ] && [ "$h1" -gt "$h0" ] &&
        pass "2 (budget $B): $((w1 - w0)) windows built, $((h1 - h0)) reused" ||
        fail "2 (budget $B): windows $w0 -> $w1, hits $h0 -> $h1"
done

ct_param_set smap_budget 100
ct_param_set smap_unbounded 1
w0="$(info smap_windows)"
GOT="$(answers)"
w1="$(info smap_windows)"
ct_param_set smap_unbounded 0
ct_param_set smap_budget 0
[ "$w1" = "$w0" ] && [ "$GOT" = "$REF" ] &&
    pass "control: with the budget lifted the whole map is built again (no window)" ||
    fail "control: windows $w0 -> $w1 with the budget lifted -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
