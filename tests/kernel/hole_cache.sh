#!/usr/bin/env bash
# a read of a hole walks the extent tree once, not once per block
#
# The DIO code and readahead ask for a hole one block at a time, and a
# lookup that misses reads every leaf whose range covers the block: a
# read of a hole in a file of ~49,000 extents did 1.3M tree reads per
# GiB. A miss now remembers the hole it proved, under the extent
# cache's key, and later reads inside it are answered from memory.
#
# A file of ~2,000 extents (a 4 KiB block every other block), then:
#   1. a 32 MiB O_DIRECT read and a 32 MiB buffered read of a hole:
#      a handful of lookup misses, not one per block; zeros read;
#   2. the hole cached, then written into -- O_DIRECT, buffered with
#      fsync, through mmap and by fallocate -- and read again: every
#      write reads back (an allocation moves the key, so the remembered
#      hole cannot answer for what filled it);
#   3. fsck clean.
#
# Two things keep a remembered hole honest: an allocation moves the
# key's block count, and every write here also ends in a conversion
# (completion, fsync, fallocate) that drops the cache. Each alone must
# be enough.
#
# DISCRIMINATION: hole_cache_off=1 -- one miss per block in case 1;
# ext_key_no_blocks=1 with ext_cache_skip_drop=1 (both guards off) --
# the writes read back as zeros until a remount; ext_cache_skip_drop=1
# alone -- the key by itself keeps every write visible.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in hole_cache_off ext_key_no_blocks ext_cache_skip_drop; do
    [ -w $P/$k ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt hc)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hole_cache_off 0
ct_param_set ext_key_no_blocks 0
ct_param_set ext_cache_skip_drop 0

DRV="$(ct_tmp hc-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, fcntl
op, path = sys.argv[1], sys.argv[2]
B = 4096
FRAG = 2048                  # blocks 0, 2, ... 4094
HOLE0, HOLE_N = 8192, 8192   # read: [8192, 16384)
W = {"dio": 20000, "buf": 20100, "mmap": 20200, "falloc": 20300}  # writes into the hole at [16384, 32768)
def stamp(i, g): return (b"B%07d/%s" % (i, g.encode())).ljust(16, b".") * 256
if op == "frag":
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    os.ftruncate(f, 32768 * B)
    buf = mmap.mmap(-1, B)
    for i in range(FRAG):
        buf[:] = stamp(2 * i, "f")
        os.pwritev(f, [buf], 2 * i * B)
    os.fsync(f); os.close(f)
elif op == "readhole":
    # O_DIRECT then buffered, 32 MiB each, 1 MiB at a time: zeros
    f = os.open(path, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, 1 << 20)
    ok = True
    for c in range(16):
        os.preadv(f, [buf], (HOLE0 + c * 256) * B)
        ok = ok and buf[:] == bytes(1 << 20)
    os.close(f)
    with open(path, "rb") as g:
        g.seek((HOLE0 + 4096) * B)
        for c in range(16):
            ok = ok and g.read(1 << 20) == bytes(1 << 20)
    print("zeros" if ok else "NONZERO")
elif op == "warm":
    # O_DIRECT reads that remember [16384, 32768) as a hole
    f = os.open(path, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, B)
    for b in (16384, 20000, 20100, 20200, 20300):
        os.preadv(f, [buf], b * B)
    os.close(f)
elif op == "writeread":
    # Each write read back at once through a second O_DIRECT descriptor,
    # before any fsync or close: a publish restamps file_seq, which is
    # one more thing that would hide a stale hole.
    r = os.open(path, os.O_RDONLY | os.O_DIRECT)
    rb = mmap.mmap(-1, B)
    def back(k):
        os.preadv(r, [rb], W[k] * B)
        return k + ("=ok" if rb[:] == stamp(W[k], "w") else ("=ZEROS" if rb[:] == bytes(B) else "=BAD"))
    res = []
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    buf = mmap.mmap(-1, B); buf[:] = stamp(W["dio"], "w")
    os.pwritev(f, [buf], W["dio"] * B)
    res.append(back("dio"))
    g = os.open(path, os.O_RDWR)
    os.pwrite(g, stamp(W["buf"], "w"), W["buf"] * B)
    res.append(back("buf"))
    m = mmap.mmap(g, 32768 * B)
    m[W["mmap"] * B:(W["mmap"] + 1) * B] = stamp(W["mmap"], "w")
    res.append(back("mmap"))
    os.posix_fallocate(g, W["falloc"] * B, B)
    os.pwrite(g, stamp(W["falloc"], "w"), W["falloc"] * B)
    res.append(back("falloc"))
    m.close()
    os.fsync(g); os.close(g); os.close(f); os.close(r)
    print(",".join(sorted(res)))
elif op == "readback":
    # O_DIRECT, so the page cache cannot answer for the map
    f = os.open(path, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, B)
    res = []
    for k, b in sorted(W.items()):
        os.preadv(f, [buf], b * B)
        res.append(k + ("=ok" if buf[:] == stamp(b, "w") else ("=ZEROS" if buf[:] == bytes(B) else "=BAD")))
    os.close(f)
    print(",".join(res))
PY
info() { sed -n "s/^$1: //p" "$PROC/info"; }

# <tag> <hole_cache_off> <ext_key_no_blocks> <ext_cache_skip_drop> -> RES
round() {
    local img dev m0 h0
    img="$(ct_image 560 "hc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    ct_param_set sparse_unit_off 1
    python3 -I "$DRV" frag "$MNT/f"
    ct_param_set sparse_unit_off 0
    echo "$2" >$P/hole_cache_off
    echo 3 >/proc/sys/vm/drop_caches
    m0="$(info ext_cache_misses)"
    h0="$(info hole_cache_hits)"
    RES="read=$(python3 -I "$DRV" readhole "$MNT/f")"
    RES="$RES misses=$(($(info ext_cache_misses) - m0)) holehits=$(($(info hole_cache_hits) - h0))"
    python3 -I "$DRV" warm "$MNT/f"
    echo "$3" >$P/ext_key_no_blocks
    echo "$4" >$P/ext_cache_skip_drop
    RES="$RES back=$(python3 -I "$DRV" writeread "$MNT/f")"
    echo 0 >$P/ext_key_no_blocks
    echo 0 >$P/ext_cache_skip_drop
    echo 0 >$P/hole_cache_off
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="$RES rback=$(python3 -I "$DRV" readback "$MNT/f")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}
get() { sed -nE "s/(^|.* )$1=([^ ]*).*/\2/p" <<<"$2"; }

ALLOK="dio=ok,falloc=ok,mmap=ok,buf=ok"
ALLOK="$(tr ',' '\n' <<<"$ALLOK" | sort | paste -sd,)"

round c 1 0 0
C="$RES"
log "control (no hole cache): $C"
round s 0 1 1
S="$RES"
log "control (both guards off): $S"
round k 0 0 1
K="$RES"
log "key alone (no drops): $K"
round f 0 0 0
R="$RES"
log "hole cache: $R"
[ "$(get misses "$C")" -ge 8000 ] && [ "$(get holehits "$C")" = 0 ] &&
    pass "control: without the hole cache a 64 MiB read of a hole misses $(get misses "$C") times" ||
    fail "control: $C -- the suite cannot tell a remembered hole from a walk"
# fallocate publishes, and the publish restamps file_seq: that write is
# guarded a third way and reads back even here.
[ "$(get back "$S")" = "buf=ZEROS,dio=ZEROS,falloc=ok,mmap=ZEROS" ] && [ "$(get rback "$S")" = "$ALLOK" ] &&
    pass "control: with both guards off a remembered hole hides every write until a remount" ||
    fail "control: both guards off, $(get back "$S") / after remount $(get rback "$S") -- case 2 cannot see a stale hole"
[ "$(get back "$K")" = "$ALLOK" ] &&
    pass "2a: with no drops at all, the key alone keeps every write into a remembered hole visible" ||
    fail "2a: the key alone: $K"
[ "$(get read "$R")" = zeros ] && [ "$(get misses "$R")" -le 64 ] && [ "$(get holehits "$R")" -ge 8000 ] &&
    pass "1: a 64 MiB read of a hole: $(get misses "$R") lookup misses, $(get holehits "$R") answered from the hole cache" ||
    fail "1: $R"
[ "$(get back "$R")" = "$ALLOK" ] && [ "$(get rback "$R")" = "$ALLOK" ] && [ "$(get back "$C")" = "$ALLOK" ] &&
    pass "2: O_DIRECT, buffered, mmap and fallocate writes into a remembered hole all read back, before and after a remount" ||
    fail "2: $R / control $C"
[ "$(get fsck_err "$R")" = 0 ] && [ "$(get fsck_err "$C")" = 0 ] && pass "3: fsck clean" ||
    fail "3: fsck $(get fsck_err "$R") / $(get fsck_err "$C")"
ct_exit
