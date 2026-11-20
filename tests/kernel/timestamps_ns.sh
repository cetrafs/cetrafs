#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# inode times keep their nanoseconds on disk, and a file has a birth time
#
# Every time in an inode record was whole seconds and there was no birth
# time: two changes inside one second left the same mtime on the device,
# which is how rsync and make decide nothing changed (audit 2026-11-15
# L-12). Format 0x000A stores signed nanoseconds and a crtime written once
# by the create.
#
# Staged on one node, a remount between writing and reading so every
# value comes back from the device, not from the in-core inode:
#   setup: a write left an mtime with a sub-second part in core;
#   1. that mtime comes back from the device to the nanosecond;
#   2. utimensat() with explicit nanoseconds, after 1970 and before it,
#      comes back exactly (atime and mtime);
#   3. statx reports a birth time, the same one after a remount, and a
#      later chmod and write do not move it;
#   4. fsck finds the volume clean.
#
# DISCRIMINATION: time_whole_seconds=1 stores whole seconds, as 0x0009
# did -- 1 and 2 fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/time_whole_seconds ] || { skip "time_whole_seconds is missing"; ct_exit; }
MNT="$(ct_mnt tsns)"
ct_track mnt "$MNT"
ct_param_set time_whole_seconds 0

field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }

# <whole_seconds 0|1> -> "subsec= m_ok= u_ok= neg_ok= birth= birth_same= birth_kept= fsck="
round() {
    local img dev before after fsck=0
    img="$(ct_image 560 "tsns$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/time_whole_seconds
    before="$(python3 -I - "$MNT" <<'PY'
import os, sys, time
m = sys.argv[1]
for n in ("f", "g", "h"):
    with open(os.path.join(m, n), "wb") as fh:
        fh.write(b"x" * 4096)
        os.fsync(fh.fileno())
# A sub-second mtime from an ordinary write (retry if the clock hit .0).
for _ in range(5):
    time.sleep(0.013)
    with open(os.path.join(m, "f"), "r+b") as fh:
        fh.write(b"y")
        os.fsync(fh.fileno())
    mt = os.stat(os.path.join(m, "f")).st_mtime_ns
    if mt % 1000000000:
        break
os.utime(os.path.join(m, "g"), ns=(1700000000123456789, 1700000000987654321))
os.utime(os.path.join(m, "h"), ns=(-1500000001, -1499999999))
for n in ("g", "h"):
    with open(os.path.join(m, n), "rb") as fh:
        os.fsync(fh.fileno())
os.sync()
print("mt=%d" % mt, flush=True)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/time_whole_seconds
    local b0 b1 b2
    b0="$(stat -c %W "$MNT/f")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    b1="$(stat -c %W "$MNT/f")"
    after="$(python3 -I - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
f, g, h = (os.stat(os.path.join(m, n)) for n in ("f", "g", "h"))
print("mt=%d gu=%d hu=%d" % (
    f.st_mtime_ns,
    1 if (g.st_atime_ns, g.st_mtime_ns) == (1700000000123456789, 1700000000987654321) else 0,
    1 if (h.st_atime_ns, h.st_mtime_ns) == (-1500000001, -1499999999) else 0), flush=True)
PY
)"
    chmod 600 "$MNT/f"
    sleep 1.1
    echo z >>"$MNT/f"
    sync
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    b2="$(stat -c %W "$MNT/f")"
    ct_umount "$MNT"
    ct_fsck "$dev" >/dev/null 2>&1 && fsck=1
    local mt0 mt1
    mt0="$(field mt "$before")" mt1="$(field mt "$after")"
    echo "subsec=$([ $((mt0 % 1000000000)) != 0 ] && echo 1 || echo 0)" \
        "m_ok=$([ "$mt0" = "$mt1" ] && echo 1 || echo 0) u_ok=$(field gu "$after") neg_ok=$(field hu "$after")" \
        "birth=$b1 birth_same=$([ "$b0" = "$b1" ] && echo 1 || echo 0)" \
        "birth_kept=$([ "$b1" = "$b2" ] && echo 1 || echo 0) fsck=$fsck mt0=$mt0 mt1=$mt1"
}

R="$(round 0)"
log "nanoseconds: $R"
C="$(round 1)"
log "control (whole seconds): $C"
for v in "$R" "$C"; do
    [ "$(field subsec "$v")" = 1 ] || { fail "setup: the write left no sub-second mtime in core ($v)"; ct_exit; }
done
pass "setup: a write left an mtime with a sub-second part in core"
[ "$(field m_ok "$R")" = 1 ] && pass "1: the write's mtime came back from the device to the nanosecond" ||
    fail "1: the mtime lost its nanoseconds on the device ($R)"
[ "$(field m_ok "$C")" = 0 ] && pass "control: stored in whole seconds, the mtime came back different" ||
    fail "control: whole seconds kept the mtime anyway -- the assertion cannot fail ($C)"
[ "$(field u_ok "$R")" = 1 ] && [ "$(field neg_ok "$R")" = 1 ] &&
    pass "2: explicit nanosecond times after and before 1970 came back exactly" ||
    fail "2: an explicit nanosecond time did not survive the device ($R)"
[ "$(field u_ok "$C")" = 0 ] && [ "$(field neg_ok "$C")" = 0 ] &&
    pass "control: stored in whole seconds, the explicit times came back different" ||
    fail "control: whole seconds kept the explicit times -- the assertion cannot fail ($C)"
B="$(field birth "$R")"
[ "$B" -gt 0 ] 2>/dev/null && [ "$(field birth_same "$R")" = 1 ] && [ "$(field birth_kept "$R")" = 1 ] &&
    pass "3: statx reports a birth time ($B), unchanged by a remount, a chmod and a write" ||
    fail "3: the birth time is missing or moved ($R)"
[ "$(field fsck "$R")" = 1 ] && pass "4: fsck finds the volume clean" || fail "4: fsck failed ($R)"
ct_exit
