#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# loops over a whole flattened extent map yield the CPU as they go
#
# The punch's dry run and compaction, the frees of an evicted file's
# extents and the defragmenter's free of a moved step walk the file's
# FLATTENED map -- up to millions of entries -- under its exclusive
# locks, and did not yield where their sibling loops do (audit
# 2026-11-22 N-18). They now yield every 4096 entries
# (cetrafs_map_yield(), counted in info as map_yields).
#
# What this cannot show: a stall. On a loop device the loops over a few
# thousand entries take milliseconds, nowhere near a soft lockup, and no
# instrument here measures scheduling latency. It shows the yields are
# REACHED on each path, which is what a later edit could lose.
#
# Files of 9000 one-block extents:
#   1. a punch of the whole range yields;
#   2. an unlink (the evict's free of every extent) yields;
#   3. a defragmentation of one yields;
#   and the files read back as expected, fsck clean.
#
# DISCRIMINATION: map_yield_off=1 (as before): no yield on any path.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/map_yield_off ] || { skip "map_yield_off is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
ct_param_set map_yield_off 0
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set scrub 0
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt mly)"
ct_track mnt "$MNT"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# make <path>: 9000 extents, every other block written
make_frag() {
    python3 -I - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(9000):
    os.pwrite(fd, b'%08d' % i * 512, i * 2 * 4096)
os.fsync(fd); os.close(fd)
PY
}

# <tag> <off 0|1> -> RES "punch= unlink= defrag= extents= err="
round() {
    local dev info y ext err
    dev="$(ct_dev 1200 "mly$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    make_frag "$MNT/p"
    make_frag "$MNT/u"
    make_frag "$MNT/d"
    sync
    # the map's own entries (fiemap lists each; filefrag's summary merges
    # entries that are physically adjacent across the holes)
    ext="$(filefrag -v "$MNT/d" 2>/dev/null | grep -cE '^ *[0-9]+:' || true)"
    echo "$2" >$P/map_yield_off
    yc() { sed -n 's/^map_yields: //p' "$info"; }
    y="$(yc)"; fallocate -p -o 0 -l $((18000 * 4096)) "$MNT/p"; sync; RES="punch=$(($(yc) - y))"
    y="$(yc)"; rm -f "$MNT/u"; sync; sleep 1; RES="$RES unlink=$(($(yc) - y))"
    y="$(yc)"; "$DEFRAG" "$MNT/d" >/dev/null 2>&1 || true; RES="$RES defrag=$(($(yc) - y))"
    echo 0 >$P/map_yield_off
    RES="$RES extents=$ext"
    RES="$RES data=$(python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
ok = all(os.pread(fd, 4096, i * 2 * 4096) == b"%08d" % i * 512 for i in range(0, 9000, 97))
z = os.pread(os.open(sys.argv[2], os.O_RDONLY), 4096, 4000 * 4096) == bytes(4096)
print("ok" if ok and z else "bad")' "$MNT/d" "$MNT/p")"
    ct_umount "$MNT"
    err="$(ct_fsck "$dev" 2>&1 | grep -c '^ERR' || true)"
    RES="$RES err=$err"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (no yields): $C"
[ "$(get extents "$R")" -ge 8000 ] || { fail "setup: the file has $(get extents "$R") extents, not ~9000"; ct_exit; }
[ "$(get punch "$R")" -ge 1 ] && pass "1: the whole-range punch yielded $(get punch "$R") time(s)" || fail "1: $R"
[ "$(get unlink "$R")" -ge 1 ] && pass "2: the unlink's free of every extent yielded $(get unlink "$R") time(s)" ||
    fail "2: $R"
[ "$(get defrag "$R")" -ge 1 ] && pass "3: the defragmentation yielded $(get defrag "$R") time(s)" || fail "3: $R"
[ "$(get data "$R")" = ok ] && [ "$(get err "$R")" = 0 ] && pass "the files read back as expected, fsck clean" ||
    fail "data/fsck: $R"
[ "$(get punch "$C")" = 0 ] && [ "$(get unlink "$C")" = 0 ] && [ "$(get defrag "$C")" = 0 ] &&
    pass "control: with the yields off, none is counted" || fail "control: $C -- yields counted from elsewhere"
ct_exit
