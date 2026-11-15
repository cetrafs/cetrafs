#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag step writes only the tree blocks it changes, and the steps build one extent
#
# Each 128-block step of the mover rebuilt the WHOLE extent tree -- every
# leaf and interior written new -- so moving a fragmented file cost the
# tree's size in synchronous writes per 512 KiB (audit 2026-11-15 A-14).
# A step now goes through the tree patch: its logical span leaves the
# tree, its pieces on the new run go in and extend the run the earlier
# steps built (cetrafs_tree_patch()).
#
# A file of 6,000 one-block extents (a depth-2 tree), defragmented:
#   1. far fewer tree blocks written than the rebuild writes;
#   2. the result is a handful of extents, not one per step;
#   3. it reads back, before and after a remount; fsck clean.
#
# DISCRIMINATION: tree_patch_off=1 rebuilds every step, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "defrag, which needs the file lock to pin"
[ -w /sys/module/cetrafs/parameters/tree_patch_off ] || { skip "tree_patch_off is missing"; ct_exit; }
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dftp)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set tree_patch_off 0
P=/sys/module/cetrafs/parameters
N=6000

DRV="$(ct_tmp dftp-drv)"
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
extents() { filefrag -v "$1" | grep -cE '^ *[0-9]+:'; }
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }

# <patch_off 0|1> -> RES
round() {
    local img w0 p0 rc=0 before
    img="$(ct_image 560 "dftp$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    INFO="$(ct_procdir "$DEV")/info"
    python3 -I "$DRV" build "$MNT/f" "$N"
    sync
    before="$(extents "$MNT/f")"
    echo "$1" >$P/tree_patch_off
    w0="$(ctr tree_blocks)" p0="$(ctr tree_patches)"
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || rc=$?
    RES="rc=$rc before=$before after=$(extents "$MNT/f") writes=$(($(ctr tree_blocks) - w0)) patches=$(($(ctr tree_patches) - p0))"
    echo 0 >$P/tree_patch_off
    RES="$RES check=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    RES="$RES remount=$(python3 -I "$DRV" check "$MNT/f" "$N")"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR|leaked' || true)"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

round 1
C="$RES"
log "control (rebuild per step): $C"
round 0
R="$RES"
log "patched: $R"
[ "$(get before "$R")" -ge 5000 ] && [ "$(get rc "$R")" = 0 ] && [ "$(get rc "$C")" = 0 ] ||
    fail "setup: the file was not fragmented or a defrag failed ($R | $C)"
[ "$(get patches "$R")" -ge 10 ] && [ "$(get writes "$R")" -lt $(($(get writes "$C") / 2)) ] &&
    pass "1: $(get patches "$R") patched steps wrote $(get writes "$R") tree blocks, the rebuild $(get writes "$C")" ||
    fail "1: $R | control $C"
[ "$(get after "$R")" -le 4 ] && pass "2: $(get before "$R") extents became $(get after "$R")" ||
    fail "2: $(get after "$R") extents after the move -- the steps did not join"
[ "$(get check "$R")" = ok ] && [ "$(get remount "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: it reads back before and after a remount; fsck clean, nothing leaked" || fail "3: $R"
ct_exit
