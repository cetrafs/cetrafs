#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag moves a sparse, preallocated file: holes stay holes, preallocation stays preallocated
#
# The mover used to decline any file with an interior hole or a
# preallocated extent -- a thin or preallocated VM image, the usual kind
# -- so the one repair for fragmentation never reached them (audit
# 2026-11-15 A-14). It now packs the MAPPED blocks into one run in
# logical order: each goes back at its own logical block, a preallocated
# extent keeps its flag and its blocks are not copied.
#
# One file, fragmented against a filler:
#   - data blocks with holes between them;
#   - a preallocated range with a few written blocks in it;
#   - one buffered store into that range still PENDING (the file held
#     open, no fsync): data to this node while the extent still says
#     preallocated, so the step must convert it before it moves anything.
# After defrag.cetra:
#   1. the mapped blocks are one physical run, in logical order;
#   2. the holes are still holes (no block behind them);
#   3. every block reads back: data, zeros for holes and preallocation,
#      the pending store's bytes -- before and after a remount;
#   4. fsck clean.
#
# DISCRIMINATION: defrag_ignore_uninit=1 (the moved extent loses its
# flag): the preallocated blocks read the device's stale bytes.
# defrag_pending_unconverted=1 (no conversion first): the pending store
# is lost.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "defrag, which needs the file lock to pin"
for k in defrag_ignore_uninit defrag_pending_unconverted convert_unit_blocks; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dfsparse)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set convert_unit_blocks 1 # the preallocated range keeps its written/preallocated pieces
ct_param_set defrag_ignore_uninit 0
ct_param_set defrag_pending_unconverted 0
P=/sys/module/cetrafs/parameters

# Layout (blocks): data at 0..63 even (holes between), preallocated
# 200..519 with 210, 230, 250 and 400 written, the pending store at 240.
# The preallocated pieces run past a step (128 blocks), so a step ends
# inside one and splits it.
DRV="$(ct_tmp dfsparse-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, time
op, path = sys.argv[1], sys.argv[2]
def stamp(i): return (b"BLK%08d" % i) * 372 + b"\0" * 4
DATA = list(range(0, 64, 2)) + [210, 230, 250, 400]
PEND = 240
if op == "build":  # the file, fragmented against a filler, then held open with a pending store
    f = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    g = os.open(path + ".fill", os.O_RDWR | os.O_CREAT, 0o644)
    os.posix_fallocate(f, 200 * 4096, 320 * 4096)
    for b in DATA:
        os.pwrite(f, stamp(b), b * 4096)
        os.fsync(f)
        os.pwrite(g, stamp(b), b * 4096)
        os.fsync(g)
    os.close(g)
    os.pwrite(f, stamp(PEND), PEND * 4096)  # buffered, not synced: pending
    sys.stdout.write("held\n"); sys.stdout.flush()
    sys.stdin.read()  # until the shell closes our stdin
    os.close(f)
elif op == "check":
    d = open(path, "rb").read()
    want = set(DATA) | ({PEND} if sys.argv[3] == "1" else set())
    bad = [i for i in range(len(d) // 4096) if d[i * 4096:(i + 1) * 4096] != (stamp(i) if i in want else b"\0" * 4096)]
    aa = [i for i in bad if d[i * 4096:i * 4096 + 4] not in (b"BLK0", b"\0\0\0\0")]
    print("ok" if not bad else "BAD_%d_first_%d_stale_%d" % (len(bad), bad[0], len(aa)))
PY
# The mapped blocks in logical order: "<runs> <mapped> <holes-mapped>",
# runs counting breaks in PHYSICAL contiguity, holes-mapped the hole
# blocks (odd ones below 64) that have a block behind them.
layout() {
    filefrag -v -b4096 "$1" | awk -F'[:. ]+' '/^ *[0-9]+:/ {
        lg = $3; le = $4; ps = $5; pe = $6
        n++; mapped += le - lg + 1
        if (n > 1 && ps != last + 1) runs++
        last = pe
        for (b = lg; b <= le; b++) if (b < 64 && b % 2) holes++
    } END { print runs + 1, mapped, holes + 0 }'
}

# <tag> <knob or -> -> RES="before=<runs> after=<runs> mapped=<b>/<a> holes=<n> check=<..> remount=<..> fsck=<..> rc=<n>"
round() {
    local img pid fifo before after rc chk
    img="$(ct_image 560 "dfsparse$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    # Free space poisoned: a block nobody wrote reads 0xAA, not zeros.
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
chunk = b"\xaa" * (1 << 20)
for i in range(320):
    os.write(fd, chunk)
os.fsync(fd); os.close(fd)' "$MNT/poison"
    rm -f "$MNT/poison"
    sync
    F="$MNT/f"
    # The writer stays open with its store pending while defrag runs.
    fifo="$(ct_tmp dfsparse-fifo)"
    rm -f "$fifo"
    mkfifo "$fifo"
    python3 -I "$DRV" build "$F" <"$fifo" >"$fifo.out" &
    pid=$!
    exec 7>"$fifo"
    for _ in $(seq 1 100); do grep -q held "$fifo.out" 2>/dev/null && break; sleep 0.1; done
    before="$(layout "$F")"
    [ "$2" != - ] && echo 1 >"$P/$2"
    rc=0
    "$DEFRAG" "$F" >/dev/null 2>&1 || rc=$?
    [ "$2" != - ] && echo 0 >"$P/$2"
    after="$(layout "$F")"
    chk="$(python3 -I "$DRV" check "$F" 1)"
    exec 7>&-
    wait "$pid" || true
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    local re
    re="$(python3 -I "$DRV" check "$F" 1)"
    ct_umount "$MNT"
    local fs
    fs="$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
    set -- $before
    local b_runs=$1 b_mapped=$2
    set -- $after
    RES="before=$b_runs after=$1 mapped=$b_mapped/$2 holes=$3 check=$chk remount=$re fsck_err=$fs rc=$rc"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

round fixed -
log "fixed: $RES"
R="$RES"
[ "$(get before "$R")" -ge 20 ] || fail "setup: the file was not fragmented ($R)"
[ "$(get rc "$R")" = 0 ] && pass "defrag moved the sparse, preallocated file" || fail "defrag refused or failed: $R"
[ "$(get after "$R")" = 1 ] && pass "1: its mapped blocks are one physical run in logical order (from $(get before "$R") runs)" ||
    fail "1: $(get after "$R") physical runs after the move ($R)"
[ "$(get holes "$R")" = 0 ] && [ "$(get mapped "$R" | cut -d/ -f1)" = "$(get mapped "$R" | cut -d/ -f2)" ] &&
    pass "2: the holes are still holes, the same $(get mapped "$R" | cut -d/ -f1) blocks mapped" ||
    fail "2: holes mapped $(get holes "$R"), mapped blocks $(get mapped "$R")"
[ "$(get check "$R")" = ok ] && [ "$(get remount "$R")" = ok ] &&
    pass "3: data, holes, preallocation and the pending store read back, before and after a remount" ||
    fail "3: $R"
[ "$(get fsck_err "$R")" = 0 ] && pass "4: fsck clean" || fail "4: fsck: $R"

round uninit defrag_ignore_uninit
log "control, defrag_ignore_uninit=1: $RES"
[ "$(get rc "$RES")" = 0 ] && [ "$(get remount "$RES")" != ok ] &&
    pass "control: without the flag on the moved extent its stale blocks are the file's ($(get remount "$RES"))" ||
    fail "control: the flag dropped and the file still reads right -- the suite cannot see it ($RES)"

round pending defrag_pending_unconverted
log "control, defrag_pending_unconverted=1: $RES"
[ "$(get rc "$RES")" = 0 ] && [ "$(get remount "$RES")" != ok ] &&
    pass "control: moved without converting first, the pending store is lost ($(get remount "$RES"))" ||
    fail "control: unconverted and still whole -- the suite cannot see the conversion ($RES)"
ct_exit
