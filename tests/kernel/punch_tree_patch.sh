#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch or truncate writes only the tree blocks it touches, and the tree it publishes is whole
#
# Punch and truncate-shrink rebuilt the WHOLE extent tree -- every leaf
# and interior written new, synchronously, with every I/O of the file
# waiting -- so one guest discard on a fragmented image cost hundreds of
# writes (audit 2026-11-15 A-11, G-2). They now copy only the leaves the
# range touches and the interiors naming them (cetrafs_tree_patch()), and
# free only the old blocks the new tree no longer names
# (cetrafs_tree_free_meta_except()).
#
# A depth-2 file of 3,000 one-block extents, the tree capped at four
# leaves per interior (TEST ONLY tree_idx_cap) so it spans three
# interiors at a loop device's scale:
#   P. a 4-block punch: at most 2 tree blocks written (one leaf, one
#      interior), not the whole tree;
#   T. a truncate that empties the last interior: the root drops it; few
#      writes; the file reads back right;
#   A. appends after both: the tree still grows (a new leaf, a new
#      interior) and every block reads back;
#   F. a punch while this inode has held-back tree blocks (an O_DIRECT
#      append not yet at a boundary): the patch reuses those blocks, so
#      they are written first -- a copy of the device then fscks with
#      nothing leaked;
#   R. after a remount: every block reads back, fsck clean, nothing
#      leaked (the old blocks went, the kept ones stayed).
#
# DISCRIMINATION: tree_patch_off=1 (rebuild, as before): P and T write
# every leaf and interior. tree_patch_no_flush=1: F's device copy names a
# leaf whose device image lacks the append, and fsck finds the appended
# block leaked.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_patch_off tree_patch_no_flush tree_idx_cap alloc_run_blocks; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt tpatch)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set tree_idx_cap 4
ct_param_set tree_patch_off 0
ct_param_set tree_patch_no_flush 0
P=/sys/module/cetrafs/parameters

# The driver: every op keeps $MODEL (the blocks written) current;
# 'check' reads the whole file against it.
DRV="$(ct_tmp tpatch-drv)"
cat >"$DRV" <<'PY'
import os, sys, ctypes, mmap, json
op, path = sys.argv[1], sys.argv[2]
mpath = os.environ["MODEL"]
model = set(json.load(open(mpath))) if os.path.getsize(mpath) else set()
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
if op == "w":  # w <file> <first> <count> <stride>: O_DIRECT, one block each
    first, count, stride = (int(x) for x in sys.argv[3:6])
    buf = mmap.mmap(-1, 4096)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    for k in range(count):
        b = first + k * stride
        buf.seek(0); buf.write(stamp(b))
        os.pwritev(fd, [buf], b * 4096)
        model.add(b)
    os.close(fd)
elif op == "punch":  # punch <file> <block> <count>
    b, n = int(sys.argv[3]), int(sys.argv[4])
    l = ctypes.CDLL("libc.so.6", use_errno=True)
    fd = os.open(path, os.O_RDWR)
    if l.fallocate(fd, 3, ctypes.c_long(b * 4096), ctypes.c_long(n * 4096)) != 0:
        sys.exit("punch: errno %d" % ctypes.get_errno())
    os.close(fd)
    model -= set(range(b, b + n))
elif op == "trunc":  # trunc <file> <blocks>
    n = int(sys.argv[3])
    os.truncate(path, n * 4096)
    model = {b for b in model if b < n}
elif op == "wpunchcopy":  # <file> <wblk> <pblk> <pn> <image> <copy>: the copy taken with the fd still open
    import subprocess
    wb, pb, pn = (int(x) for x in sys.argv[3:6])
    buf = mmap.mmap(-1, 4096); buf.write(stamp(wb))
    fd = os.open(path, os.O_RDWR | os.O_DIRECT)
    os.pwritev(fd, [buf], wb * 4096)
    model.add(wb)
    l = ctypes.CDLL("libc.so.6", use_errno=True)
    if l.fallocate(fd, 3, ctypes.c_long(pb * 4096), ctypes.c_long(pn * 4096)) != 0:
        sys.exit("punch: errno %d" % ctypes.get_errno())
    model -= set(range(pb, pb + pn))
    subprocess.run(["cp", "--sparse=always", sys.argv[6], sys.argv[7]], check=True)
    os.close(fd)
elif op == "check":
    d = open(path, "rb").read()
    bad = [i for i in range(len(d) // 4096)
           if d[i * 4096:(i + 1) * 4096] != (stamp(i) if i in model else b"\0" * 4096)]
    miss = [b for b in model if b * 4096 >= len(d)]
    print("ok" if not bad and not miss else "BAD %d first %s missing %d" % (len(bad), bad[:1], len(miss)))
    sys.exit(0)
json.dump(sorted(model), open(mpath, "w"))
PY
MODEL="$(ct_tmp tpatch-model)"
export MODEL
NODE_POKE="$(ct_helper node_poke)"
drv() { python3 -I "$DRV" "$@"; }
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }

# <patch_off 0|1> -> RES="p_writes=<n> p_patches=<n> t_writes=<n> t_patches=<n> check=<ok|BAD..>"
scenario() {
    local img w0 p0 w1 p1 w2 p2 c
    img="$(ct_image 560 "tpatch$1")"
    DEV="$(ct_loop "$img")"
    IMG="$img"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    INFO="$(ct_procdir "$DEV")/info"
    F="$MNT/f"
    : >"$MODEL"
    drv w "$F" 0 3000 2 # 3,000 one-block extents, blocks 0..5998
    sync
    echo "$1" >$P/tree_patch_off
    w0="$(ctr tree_blocks)" p0="$(ctr tree_patches)"
    drv punch "$F" 601 4 # blocks 602 and 604, in the second leaf
    w1="$(ctr tree_blocks)" p1="$(ctr tree_patches)"
    drv trunc "$F" 4000 # extents 2000..2999 go: the last interior empties
    w2="$(ctr tree_blocks)" p2="$(ctr tree_patches)"
    c="$(drv check "$F")"
    echo 0 >$P/tree_patch_off
    RES="p_writes=$((w1 - w0)) p_patches=$((p1 - p0)) t_writes=$((w2 - w1)) t_patches=$((p2 - p1)) check=${c// /_}"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

log "control: the rebuild (tree_patch_off=1)"
scenario 1
C="$RES"
log "control: $C"
ct_umount "$MNT"
log "patched"
scenario 0
R="$RES"
log "patched: $R"

[ "$(get p_writes "$C")" -ge 8 ] && [ "$(get t_writes "$C")" -ge 6 ] ||
    fail "control setup: the rebuild wrote only $(get p_writes "$C") / $(get t_writes "$C") tree blocks -- the tree is not the one this suite needs ($C)"
[ "$(get check "$C")" = ok ] || fail "control: the rebuilt file reads back wrong ($C)"
[ "$(get p_patches "$R")" = 1 ] && [ "$(get p_writes "$R")" -le 2 ] &&
    pass "P: the punch wrote $(get p_writes "$R") tree block(s), the rebuild $(get p_writes "$C")" ||
    fail "P: $R"
[ "$(get t_patches "$R")" = 1 ] && [ "$(get t_writes "$R")" -le 2 ] &&
    pass "T: the truncate wrote $(get t_writes "$R") tree block(s), the rebuild $(get t_writes "$C")" ||
    fail "T: $R"
[ "$(get check "$R")" = ok ] && pass "P, T: every block reads back, the punched and truncated ones as zeros" ||
    fail "P, T: $(get check "$R")"

log "A: appends after the punch and the truncate"
drv w "$F" 4001 300 2
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "A: 300 appends after the edits read back" || fail "A: $OUT"

# F <no_flush 0|1> <append block> <punch block> -> "leaked=<n> err=<n> why=<..>"
# The append's leaf edit is held back until a boundary, and the last
# close is one: append, punch and copy happen with the file still open.
flushcase() {
    local copy out
    copy="$(ct_tmp "tpatch-copy$1")"
    echo "$1" >$P/tree_patch_no_flush
    drv wpunchcopy "$F" "$2" "$3" 1 "$IMG" "$copy"
    echo 0 >$P/tree_patch_no_flush
    # The copy's registry still says this node is mounted; fsck would
    # watch it heartbeat for two minutes. It is a copy: mark it departed.
    "$NODE_POKE" "$copy" 0 0 00 0 >/dev/null
    out="$(ct_fsck "$(ct_loop "$copy")" 2>&1 || true)"
    echo "ran=$(grep -c 'cetrafs fsck: OK\|problem(s) found' <<<"$out" || true) err=$(grep -c '^ERR' <<<"$out" || true) extents=$(sed -n 's/.*content: [0-9]* inodes, \([0-9]*\) extents.*/\1/p' <<<"$out")"
}
R2="$(flushcase 0 6001 2)"
log "F, flushed: $R2"
R3="$(flushcase 1 6003 6)"
log "F, control (tree_patch_no_flush=1): $R3"
[ "$(get ran "$R2")" = 1 ] && [ "$(get ran "$R3")" = 1 ] || fail "F setup: fsck did not run over the device copies ($R2 | $R3)"
# Each case appends one one-block extent and punches one: a device copy
# holding both edits has as many extents after the second case as after
# the first; one that lost the held-back append has one fewer.
[ -n "$(get extents "$R2")" ] && [ "$(get err "$R2")" = 0 ] && pass "F: the device copy after the punch is consistent (no ERR)" ||
    fail "F: $R2"
FX="$(get extents "$R2")"
R4="$(flushcase 0 6005 10)"
log "F, flushed again: $R4"
[ "$(get extents "$R4")" = "$FX" ] && pass "F: the held-back append reached the device with the punch's publish ($FX extents)" ||
    fail "F: the device copy has $(get extents "$R4") extents, not $FX ($R2 | $R4)"
[ "$(get extents "$R3")" = $((FX - 1)) ] && pass "F control: unflushed, the device copy lost the held-back append" ||
    fail "F control: unflushed, the copy has $(get extents "$R3") extents (flushed: $FX) -- the suite cannot see the flush"

log "R: after a remount"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
OUT="$(drv check "$F")"
[ "$OUT" = ok ] && pass "R: every block reads back after a remount" || fail "R: $OUT"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR|leaked' <<<"$OUT" && fail "R: fsck: $(grep -E '^ERR|leaked' <<<"$OUT" | head -3)" ||
    pass "R: fsck clean, nothing leaked"
ct_exit
