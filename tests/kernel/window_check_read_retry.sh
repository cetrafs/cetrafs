#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tree flush's read-back that fails once is retried, not called a loss
#
# After a boundary writes a file's held-back tree blocks it reads each
# one back, and the record's stamp, to catch a peer that wrote inside
# its window (F-71) -- and marks the file damaged if one does not match.
# A read that merely FAILED counted the same: one transient read error,
# from the device that had just accepted the write, refused every later
# write to a healthy file (N-7). Read errors are now retried with the
# tear backoff; a mismatch is still a loss; a read that keeps failing is
# reported as unverified and counted, not called damage.
#
# A preallocated file whose spaced O_DIRECT writes spill its map into a
# leaf; then one more write and fsync, with the read-back failing:
#   A. the next block read-back fails once (window_read_fail=1);
#   B. the next stamp read fails once (window_read_fail=2);
#   C. every read-back fails (window_read_fail=4): unverified;
# in each: the file is not marked damaged, and a later write succeeds.
# C also logs the read-back as unverified.
#
# DISCRIMINATION: window_read_no_retry=1 restores the old judgement:
# round A's file is marked damaged and the later write fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in window_read_fail window_read_no_retry; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt wcrr)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set window_read_fail 0
ct_param_set window_read_no_retry 0
P=/sys/module/cetrafs/parameters

dio_write() { # <path> <block> <tag> [fsync]
    python3 -I - "$@" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(sys.argv[3].encode() * (4096 // len(sys.argv[3])))
os.pwritev(fd, [buf], int(sys.argv[2]) * 4096)
if len(sys.argv) > 4:
    os.fsync(fd)
os.close(fd)
PY
}

# <tag> <fail mask> <no_retry 0|1> -> RES "damaged= later= unverified= injected="
round() {
    local dev f mark dmg=0 later=0 unv=0 inj=0
    dev="$(ct_dev 560 "wcrr$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    f="$MNT/img"
    fallocate -l $((4 << 20)) "$f"
    # 64 apart: every write its own extent, and the map spills into a leaf.
    for i in $(seq 0 6); do dio_write "$f" $((i * 64)) "$(printf 'B%07d' $((i * 64)))"; done
    dio_write "$f" 448 B0000448 fsync
    echo "$3" >$P/window_read_no_retry
    mark="$(dmesg_mark)"
    echo "$2" >$P/window_read_fail
    dio_write "$f" 900 OURS0900 fsync 2>/dev/null || true
    echo 0 >$P/window_read_fail
    echo 0 >$P/window_read_no_retry
    dio_write "$f" 960 LATE0960 fsync 2>/dev/null && later=1
    dmesg_since "$mark" | grep -q 'the file is marked damaged' && dmg=1
    dmesg_since "$mark" | grep -q 'could not be read back -- not verified' && unv=1
    dmesg_since "$mark" | grep -q 'window_read_fail: failed a' && inj=1
    umount "$MNT"
    RES="damaged=$dmg later=$later unverified=$unv injected=$inj"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

round c 1 1
C="$RES"; log "control (no retry), block read-back fails once: $C"
round a 1 0
A="$RES"; log "A: block read-back fails once: $A"
round b 2 0
B="$RES"; log "B: stamp read fails once: $B"
round d 4 0
D="$RES"; log "C: every read-back fails: $D"
for r in "A:$A" "B:$B" "C:$D"; do
    n="${r%%:*}"; v="${r#*:}"
    [ "$(get injected "$v")" = 1 ] || { fail "$n: setup: no read-back failure was injected ($v)"; continue; }
    [ "$(get damaged "$v")" = 0 ] && [ "$(get later "$v")" = 1 ] &&
        pass "$n: the file is not marked damaged, and a later write succeeds" || fail "$n: $v"
done
[ "$(get unverified "$D")" = 1 ] && pass "C: the read-back that kept failing is reported as unverified" ||
    fail "C: no 'not verified' report ($D)"
[ "$(get injected "$C")" = 1 ] && [ "$(get damaged "$C")" = 1 ] && [ "$(get later "$C")" = 0 ] &&
    pass "control: without the retry one failed read marks the file damaged and refuses the next write" ||
    fail "control: $C -- the injected failure did not reach the judgement"
ct_exit
