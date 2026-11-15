#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag moves a file into several free runs when no single one is large enough
#
# The mover needed ONE free run the size of the whole file, inside one
# Block Group, so a file larger than the largest free run -- any image
# larger than a Block Group, or any file on an aged volume -- was never
# defragmented (audit 2026-11-15 A-14). The destination is now a list of
# runs ("segments"), each allocated when the one before is committed: as
# large as what is left, or the largest that fits.
#
# A file of 4,000 one-block extents, then the volume's free space cut
# into 1,200-block runs (a preallocated filler with holes punched in it):
#   1. defrag.cetra moves it, using several segments;
#   2. each segment is one physical run: the file is at most that many;
#   3. it reads back before and after a remount; fsck clean.
#
# DISCRIMINATION: defrag_one_run=1 (one run the size of the file, as
# before): the move fails for want of one, the file left as it was.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "defrag, which needs the file lock to pin"
[ -w /sys/module/cetrafs/parameters/defrag_one_run ] || { skip "defrag_one_run is missing"; ct_exit; }
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dfseg)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set defrag_one_run 0
P=/sys/module/cetrafs/parameters
N=4000

DRV="$(ct_tmp dfseg-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, ctypes
op, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
if op == "build":
    buf = mmap.mmap(-1, 4096)
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    g = os.open(path + ".fill", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    for b in range(n):  # interleaved: every block of f its own extent
        buf.seek(0); buf.write(stamp(b))
        os.pwritev(f, [buf], b * 4096)
        os.pwritev(g, [buf], b * 4096)
    os.close(g); os.close(f)
    # Free space cut into 1,200-block runs: preallocate nearly all of it,
    # then punch a 1,200-block hole every 3,000 blocks.
    st = os.statvfs(os.path.dirname(path))
    blocks = st.f_bavail * st.f_frsize // 4096 - 1024
    h = os.open(path + ".cut", os.O_RDWR | os.O_CREAT, 0o644)
    while blocks > 0:
        try:
            os.posix_fallocate(h, 0, blocks * 4096)
            break
        except OSError:
            blocks -= 1024
    l = ctypes.CDLL("libc.so.6", use_errno=True)
    holes = 0
    for at in range(1000, blocks - 1200, 3000):
        if l.fallocate(h, 3, ctypes.c_long(at * 4096), ctypes.c_long(1200 * 4096)) == 0:
            holes += 1
    os.close(h)
    print(holes)
else:
    d = open(path, "rb").read()
    bad = [i for i in range(n) if d[i * 4096:(i + 1) * 4096] != stamp(i)]
    print("ok" if len(d) == n * 4096 and not bad else "BAD_%d" % len(bad))
PY
# physical runs of a file, in logical order
runs() {
    filefrag -v -b4096 "$1" | awk -F'[:. ]+' '/^ *[0-9]+:/ { if (n++ && $5 != last + 1) r++; last = $6 } END { print r + 1 }'
}
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }

# <one_run 0|1> -> RES
round() {
    local img s0 rc=0 before holes
    img="$(ct_image 560 "dfseg$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    INFO="$(ct_procdir "$DEV")/info"
    holes="$(python3 -I "$DRV" build "$MNT/f" "$N")"
    sync
    before="$(runs "$MNT/f")"
    echo "$1" >$P/defrag_one_run
    s0="$(ctr defrag_segments)"
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || rc=$?
    echo 0 >$P/defrag_one_run
    RES="rc=$rc holes=$holes before=$before after=$(runs "$MNT/f") segments=$(($(ctr defrag_segments) - s0))"
    RES="$RES check=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    RES="$RES remount=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

round 1
C="$RES"
log "control (one run or nothing): $C"
round 0
R="$RES"
log "segments: $R"
[ "$(get holes "$R")" -ge 10 ] && [ "$(get before "$R")" -ge 3000 ] ||
    fail "setup: the free space was not cut or the file not fragmented ($R)"
[ "$(get rc "$C")" != 0 ] && [ "$(get after "$C")" = "$(get before "$C")" ] && [ "$(get check "$C")" = ok ] &&
    pass "control: with one run required the move fails, the file left as it was" ||
    fail "control: one run required and the move still happened -- the free space has a run the file's size ($C)"
[ "$(get rc "$R")" = 0 ] && [ "$(get segments "$R")" -ge 3 ] &&
    pass "1: moved into $(get segments "$R") segments" || fail "1: $R"
[ "$(get after "$R")" -le "$(get segments "$R")" ] &&
    pass "2: $(get before "$R") physical runs became $(get after "$R")" || fail "2: $R"
[ "$(get check "$R")" = ok ] && [ "$(get remount "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: it reads back before and after a remount; fsck clean" || fail "3: $R"
ct_exit
