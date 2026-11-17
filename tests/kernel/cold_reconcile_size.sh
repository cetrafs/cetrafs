#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held fd sees the size a peer's change left, not the size it opened with
#
# Under nofilelock a peer's publish moves the record's file_seq, and the
# node holding the file open marks its tree cold; the reconcile dropped
# the tree and the clean pages -- and kept the in-core size. fstat,
# SEEK_END and every read clamp at it, so a migration destination that
# opened a growing image before the source's last appends read the new
# range short, and qemu zero-fills a short read (audit 2026-11-15 B-10).
# The reconcile now applies the fresh record's size and block count when
# this node has no unpublished size of its own.
#
# Single node: the peer's publish is the record rewritten on the backing
# file (inode_lock_poke --peer-size: the larger size, file_seq stamped by
# row 1). The data is the file's own: written 64 blocks long, the record
# cut to 16 before the mount, so the extents for 16..63 are there.
#   setup: the held O_RDWR fd opens at 16 blocks;
#   1. after the peer's publish and one read through the fd, fstat and
#      SEEK_END say 64 blocks;
#   2. an O_DIRECT read of block 40 through the same fd returns its data.
#   3. the same with the reconcile's inode-lock trylock lost once
#      (apply_trylock_fail_once, as to an O_DIRECT read in flight, which
#      holds i_rwsem shared): the size still arrives within the second.
#      One lost trylock used to park the reconcile until the next
#      heartbeat, the fd reading short meanwhile -- on an arm64 host it
#      lost to the suite's own read every time.
#
# DISCRIMINATION: cold_size_off=1 (the old reconcile): 1 and 2 fail;
# cold_size_retry_off=1 (one trylock, then the park): 3 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cold_size_off cold_size_retry_off apply_trylock_fail_once; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set cold_size_off 0
ct_param_set cold_size_retry_off 0
ct_param_set apply_trylock_fail_once 0
POKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt crs)"
ct_track mnt "$MNT"

# <cold_size_off 0|1> <cold_size_retry_off 0|1> <contend 0|1>
#   -> "open=<blocks> size=<blocks> end=<blocks> data=<ok|short|bad>"
round() {
    local img dev ino
    img="$(ct_image 560 "crs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    python3 -c "
import os
fd = os.open('$MNT/img', os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(64):
    os.pwrite(fd, (b'%08d' % i) * 512, i * 4096)
os.fsync(fd); os.close(fd)"
    ino="$(stat -c %i "$MNT/img")"
    umount "$MNT"
    "$POKE" "$img" --peer-size "$ino" $((16 * 4096)) 0 >/dev/null # cut to 16, still our own stamp
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/cold_size_off
    echo "$2" >/sys/module/cetrafs/parameters/cold_size_retry_off
    python3 - "$MNT/img" "$img" "$ino" "$POKE" "$3" <<'PY'
import os, sys, mmap, subprocess, time
path, img, ino, poke, contend = sys.argv[1:6]
buf = mmap.mmap(-1, 4096)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
opened = os.fstat(fd).st_size // 4096
subprocess.run([poke, img, "--peer-size", ino, str(64 * 4096), "1"], check=True, stdout=subprocess.DEVNULL)
if contend == "1":
    open("/sys/module/cetrafs/parameters/apply_trylock_fail_once", "w").write("1")
time.sleep(1.2)                     # past the once-a-second verdict
os.preadv(fd, [buf], 0)             # the gate reads the record, sees the peer's stamp
time.sleep(1)                       # the reconcile runs
size = os.fstat(fd).st_size // 4096
end = os.lseek(fd, 0, os.SEEK_END) // 4096
n = os.preadv(fd, [buf], 40 * 4096)
data = "short" if n < 4096 else ("ok" if buf[:] == (b"%08d" % 40) * 512 else "bad")
os.close(fd)
print(f"open={opened} size={size} end={end} data={data}")
PY
    echo 0 >/sys/module/cetrafs/parameters/cold_size_off
    echo 0 >/sys/module/cetrafs/parameters/cold_size_retry_off
    echo 0 >/sys/module/cetrafs/parameters/apply_trylock_fail_once
    umount "$MNT"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0 0 0)"
log "fixed: $R"
C="$(round 1 0 0)"
log "control (old reconcile): $C"
R3="$(round 0 0 1)"
log "3: contended once: $R3"
C3="$(round 0 1 1)"
log "3 control (one trylock, then the park): $C3"
[ "$(get open "$R")" = 16 ] && [ "$(get open "$C")" = 16 ] || { fail "setup: the fd did not open at 16 blocks ($R | $C)"; ct_exit; }
pass "setup: the held fd opened at 16 blocks"
[ "$(get size "$R")" = 64 ] && [ "$(get end "$R")" = 64 ] && pass "1: fstat and SEEK_END follow the peer's size (64 blocks)" ||
    fail "1: the held fd still says size=$(get size "$R") end=$(get end "$R")"
[ "$(get data "$R")" = ok ] && pass "2: block 40 reads back through the held fd" || fail "2: block 40 read $(get data "$R")"
[ "$(get size "$C")" = 16 ] && [ "$(get data "$C")" = short ] && pass "control: the old reconcile kept 16 blocks and read short" ||
    fail "control: the old reconcile did not keep the opening size ($C) -- the suite does not reach it"
[ "$(get size "$R3")" = 64 ] && [ "$(get data "$R3")" = ok ] &&
    pass "3: a reconcile that lost the inode lock once still applies the size within the second" ||
    fail "3: with the inode lock lost once the held fd says size=$(get size "$R3"), block 40 $(get data "$R3")"
[ "$(get size "$C3")" = 16 ] &&
    pass "3 control: one trylock and the park leave the fd at 16 blocks" ||
    fail "3 control: the single-trylock reconcile still applied the size ($C3) -- the suite does not reach the contention"
ct_exit
