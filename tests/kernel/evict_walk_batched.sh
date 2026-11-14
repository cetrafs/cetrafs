#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the evict of a closed, fragmented file reads its extent leaves together
#
# An unlink of a file nobody has open evicts it, and the evict must read
# every extent leaf of the tree before it can free a block. With no open
# lock held the tree cache is not trusted, so each leaf was read fresh and
# in turn: one device round trip per leaf, ~1000 before an unlink freed
# anything (audit 2026-11-14 P12). An untrusted walk now reads each index
# block's leaves as one batch, and the trusted walk does the same for the
# leaves it has to read.
#
# Setup: 20000 extents (depth 2: about 80 extent leaves, one index block),
# caches dropped, on a volume whose device answers each request after a
# fixed delay (dm-delay). rm of the file is the evict. A second file of
# known content must read back, and fsck must be clean afterwards.
#   1. fixed: the rm is clearly faster than the serial walk;
#   2. control (flatten_prefetch_off): one round trip per leaf, the slow walk.
#
# DISCRIMINATION: flatten_prefetch_off is assertion 2 itself. The serial
# walk must take at least 40 device delays, or the setup did not produce
# enough leaves to tell the walks apart, and the suite fails on that first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/flatten_prefetch_off ] || { skip "flatten_prefetch_off is missing"; ct_exit; }
command -v dmsetup >/dev/null 2>&1 || { skip "dmsetup is not installed"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt ewb)"
ct_track mnt "$MNT"
ct_param_set flatten_prefetch_off 0
DELAY=5
NEXT=20000

# Two whole-tree FIEMAP walks on one open file; prints "<walk 1 ms> <walk 2 ms>".
read -r -d '' WALK_PY <<'PY' || true
import fcntl, os, struct, sys, time
FS_IOC_FIEMAP = 0xC020660B
fd = os.open(sys.argv[1], os.O_RDONLY)
def walk():
    start, total = 0, 0
    while True:
        buf = bytearray(32 + 56 * 512)
        struct.pack_into("QQIII", buf, 0, start, (1 << 63) - 1, 0, 0, 512)
        fcntl.ioctl(fd, FS_IOC_FIEMAP, buf)
        m = struct.unpack_from("I", buf, 20)[0]
        if m == 0:
            break
        total += m
        lg, _ph, ln, _a, _b, fl = struct.unpack_from("QQQQQI", buf, 32 + 56 * (m - 1))
        start = lg + ln
        if fl & 1:
            break
    return total
ms = []
for _ in range(2):
    t = time.time()
    walk()
    ms.append(int((time.time() - t) * 1000))
print(ms[0], ms[1])
PY

# <prefetch_off 0|1> -> "<rm ms> <extents> <keep ok|bad> <fsck ok|bad> <warm walk ms>"
probe() {
    local dev t0 t1 ext ok fk sum
    dev="$(ct_delay_dev 800 "$DELAY" ewb$1)"
    [ -n "$dev" ] || { skip "could not create a delayed device"; ct_exit; }
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    python3 -I - "$MNT/frag" "$MNT/keep" "$NEXT" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
blk = b"x" * 4096
for i in range(int(sys.argv[3])):       # one block, then a hole: one extent each
    os.pwrite(f, blk, i * 8192)
os.fsync(f)
os.close(f)
k = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT, 0o644)
os.write(k, os.urandom(1 << 20))
os.fsync(k)
os.close(k)
PY
    sum="$(md5sum <"$MNT/keep")"
    sync
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    echo 3 >/proc/sys/vm/drop_caches
    # filefrag -v: one line per extent. (The summary line undercounts this
    # volume's extents, 8 for 20000, so it is not used.)
    ext="$(filefrag -v "$MNT/frag" 2>/dev/null | awk '/^ *[0-9]+:/ {n++} END {print n + 0}')"
    # Warm the tree cache inside ONE open: two whole-tree FIEMAP walks, the
    # second served from the cache (a close or a new open drops it, so the
    # warm walk must come from the same open). The printed time of that
    # second walk is the setup proof that the leaves are CACHED when the
    # evict runs. The rm below is a closed file's evict, which does not
    # trust the cache and must read every leaf fresh -- the case measured.
    warm="$(python3 -I -c "$WALK_PY" "$MNT/frag" | awk '{print $2}')"
    echo "$1" >$P/flatten_prefetch_off
    t0="$(date +%s%N)"
    rm -f "$MNT/frag"
    t1="$(date +%s%N)"
    echo 0 >$P/flatten_prefetch_off
    [ "$(md5sum <"$MNT/keep")" = "$sum" ] && ok=ok || ok=bad
    ct_umount "$MNT"
    fk=ok
    ct_fsck "$dev" >/dev/null 2>&1 || fk=bad
    echo "$(((t1 - t0) / 1000000)) ${ext:-0} $ok $fk $warm"
}

read -r MS EXT OK FK WARM <<<"$(probe 0)"
read -r CMS CEXT COK CFK CWARM <<<"$(probe 1)"
log "fixed (read as a batch): rm of the closed file took ${MS} ms ($EXT extents); control (serial): ${CMS} ms; warm walk ${WARM} ms"
# setup: the leaves were cached when the evict ran (a warm walk is fast), so the evict's reads were forced fresh by its trust rule
[ "$WARM" -lt $((DELAY * 10)) ] && [ "$CWARM" -lt $((DELAY * 10)) ] ||
    fail "setup: the warm walk took ${WARM} ms (control ${CWARM} ms) -- the tree was not cached, so the evict's reads were not a forced-fresh case"
pass "setup: the tree is cached before the evict (warm walk ${WARM} ms, control ${CWARM} ms)"
# setup: a depth-2 tree (more than one extent leaf) with a serial walk long enough to tell it apart
[ "$EXT" -gt 254 ] && [ "$CEXT" -gt 254 ] || fail "setup: the file has $EXT extents -- not a depth-2 tree"
[ "$CMS" -ge $((DELAY * 40)) ] || fail "setup: the serial walk took only ${CMS} ms -- too few leaves to tell the walks apart"
[ "$OK" = ok ] && [ "$COK" = ok ] && pass "data: the other file reads back after the evicts" || fail "data: the other file changed (fixed $OK, control $COK)"
[ "$FK" = ok ] && [ "$CFK" = ok ] && pass "fsck is clean after both evicts" || fail "fsck reported errors (fixed $FK, control $CFK)"
[ $((MS * 10)) -lt $((CMS * 7)) ] && pass "1: the evict reads the leaves together (${MS} ms vs ${CMS} ms serial)" ||
    fail "1: the evict took ${MS} ms, not clearly below the serial ${CMS} ms"
[ "$CMS" -gt "$MS" ] && pass "control: one read per leaf is the slower evict (${CMS} ms) -- the suite discriminates" ||
    fail "control: the serial evict was not slower (${CMS} ms vs ${MS} ms)"
ct_exit
