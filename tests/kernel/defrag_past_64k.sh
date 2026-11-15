#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag moves a file of more than 65,536 extents
#
# The mover declined any file past 65,536 extents, so the most
# fragmented files -- the ones that need it most -- were never repaired
# (audit 2026-11-15 A-14). The cap was there because each step rebuilt
# the whole tree; a step now patches only what it touches, and the cap
# is the tree's own capacity.
#
# A file of 70,000 one-block extents (interleaved with a filler):
#   1. defrag.cetra moves it into a handful of extents;
#   2. it reads back before and after a remount; fsck clean.
#
# DISCRIMINATION: defrag_extent_cap=65536 (the old cap): declined, the
# file left as it was.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "defrag, which needs the file lock to pin"
[ -w /sys/module/cetrafs/parameters/defrag_extent_cap ] || { skip "defrag_extent_cap is missing"; ct_exit; }
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt df64k)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set defrag_extent_cap 0
P=/sys/module/cetrafs/parameters
N=70000

DRV="$(ct_tmp df64k-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap
op, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
if op == "build":  # interleaved with a filler: every block its own extent
    buf = mmap.mmap(-1, 4096)
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    g = os.open(path + ".fill", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    for b in range(n):
        buf.seek(0); buf.write(stamp(b))
        os.pwritev(f, [buf], b * 4096)
        os.pwritev(g, [buf], b * 4096)
    os.close(g); os.close(f)
else:
    d = open(path, "rb").read()
    bad = [i for i in range(n) if d[i * 4096:(i + 1) * 4096] != stamp(i)]
    print("ok" if len(d) == n * 4096 and not bad else "BAD_%d_len_%d" % (len(bad), len(d)))
PY
extents() { filefrag "$1" | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p'; }

# <tag> <cap> -> RES
round() {
    local img dev rc=0 before t0
    img="$(ct_image 1400 "df64k$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    python3 -I "$DRV" build "$MNT/f" "$N"
    sync
    before="$(extents "$MNT/f")"
    echo "$2" >$P/defrag_extent_cap
    t0=$SECONDS
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || rc=$?
    echo 0 >$P/defrag_extent_cap
    RES="rc=$rc before=$before after=$(extents "$MNT/f") secs=$((SECONDS - t0))"
    RES="$RES check=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="$RES remount=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

round c 65536
C="$RES"
log "control (the old 65,536 cap): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get before "$R")" -gt 65536 ] && [ "$(get before "$C")" -gt 65536 ] ||
    { fail "setup: the file has $(get before "$R") extents, not past 65,536"; ct_exit; }
[ "$(get rc "$C")" != 0 ] && [ "$(get after "$C")" = "$(get before "$C")" ] && [ "$(get check "$C")" = ok ] &&
    pass "control: with the old cap the file is declined and left as it was" ||
    fail "control: the old cap did not decline it ($C)"
[ "$(get rc "$R")" = 0 ] && [ "$(get after "$R")" -le 8 ] &&
    pass "1: $(get before "$R") extents became $(get after "$R") in $(get secs "$R") s" || fail "1: $R"
[ "$(get check "$R")" = ok ] && [ "$(get remount "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: it reads back before and after a remount; fsck clean" || fail "2: $R"
ct_exit
