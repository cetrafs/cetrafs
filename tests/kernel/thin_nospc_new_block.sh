#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a thin pool out of space fails the operation, not the mount
#
# Any metadata write the device refused stopped the mount. A buffer write
# reported only "did not complete", so a thin LUN's definite "space
# allocation failed" (BLK_STS_NOSPC: SCSI DATA PROTECT 27/07, dm-thin with
# error_if_no_space) read like a medium error: one full pool stopped
# every node writing to it, every guest in EIO, and freeing space on the
# array brought nothing back (audit 2026-11-14 A-4). Metadata writes now
# carry the block layer's own status, and a NEW block -- a tree leaf or
# interior, a directory or xattr block, which nothing references until
# its write returned -- refused for space fails its operation with
# ENOSPC; the block is forgotten and freed, the mount stays up. Every
# other metadata write still stops it.
#
# Staged on a real dm-thin pool (error_if_no_space) over loop devices:
# the volume on one thin device, a second thin device fills the pool.
# Then 4 KiB O_DIRECT writes at a stride into a fresh file, until one
# needs a new extent leaf -- whose write the full pool refuses.
#   setup: a new metadata block was refused for space;
#   1. the mount did not stop;
#   2. the write that needed it failed ENOSPC;
#   3. once the pool has space again (the filler deleted), the same
#      writes succeed, without a remount;
#   4. fsck: no ERR.
#
# DISCRIMINATION: nospc_stops=1 (the old verdict): 1 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/nospc_stops ] || { skip "nospc_stops is missing"; ct_exit; }
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_thin_pool 2>/dev/null || true
grep -q thin-pool <(dmsetup targets) || { skip "no dm thin-pool target"; ct_exit; }
MNT="$(ct_mnt tnospc)"
ct_track mnt "$MNT"
ct_param_set nospc_stops 0
ct_param_set scrub 0

# <old 0|1> -> "nospc=<n> refused=<0|1> stopped=<yes|no> enospc=<0|1> after=<ok|errno> fsck=<clean|ERR>"
round() {
    local meta data pool tv0 tv1 dev proc mark out refused=0
    meta="$(ct_loop "$(ct_image 16 "tnmeta$1")")"
    data="$(ct_loop "$(ct_image 400 "tndata$1")")"
    dd if=/dev/zero of="$meta" bs=4096 count=1 conv=fsync status=none
    pool="cetra-tnp$$-$1"
    tv0="cetra-tnv$$-$1"
    tv1="cetra-tnf$$-$1"
    dmsetup create "$pool" --table "0 $(blockdev --getsz "$data") thin-pool $meta $data 128 0 1 error_if_no_space"
    ct_track dm "$pool"
    dmsetup message "$pool" 0 "create_thin 0"
    dmsetup message "$pool" 0 "create_thin 1"
    dmsetup create "$tv0" --table "0 $((1200 * 2048)) thin /dev/mapper/$pool 0"
    ct_track dm "$tv0"
    dmsetup create "$tv1" --table "0 $((1200 * 2048)) thin /dev/mapper/$pool 1"
    ct_track dm "$tv1"
    dev="/dev/mapper/$tv0"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="/proc/fs/cetrafs/$(basename "$(readlink -f "$dev")")"
    dd if=/dev/zero of="$MNT/base" bs=1M count=4 oflag=direct status=none
    echo "$1" >/sys/module/cetrafs/parameters/nospc_stops
    # the filler takes every free chunk of the pool
    dd if=/dev/zero of="/dev/mapper/$tv1" bs=1M oflag=direct status=none 2>/dev/null || true
    log "pool after the filler: $(dmsetup status "$pool" | awk '{print $6}')" >&2
    local n0
    n0="$(sed -n 's/^meta_nospc: //p' "$proc/info")"
    mark="$(dmesg_mark)"
    out="$(python3 - "$MNT/f" <<'PY'
import os, sys, mmap, errno
buf = mmap.mmap(-1, 4096)
buf.write(b"y" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
res = "none"
for i in range(64):
    try:
        os.pwrite(fd, buf, i * 2 * 4096)
    except OSError as e:
        res = errno.errorcode.get(e.errno, str(e.errno))
        if e.errno == errno.ENOSPC:
            break
os.close(fd)
print(res)
PY
)" || true
    dmesg_since "$mark" | grep -qE "no space for a new metadata block|refused a metadata write .*-28" && refused=1
    local nospc stopped enospc after
    nospc=$(($(sed -n 's/^meta_nospc: //p' "$proc/info" 2>/dev/null || echo "$n0") - n0))
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls" 2>/dev/null || echo yes)"
    [ "$out" = ENOSPC ] && enospc=1 || enospc=0
    echo 0 >/sys/module/cetrafs/parameters/nospc_stops
    # the array gets space back: the filler goes
    dmsetup remove "$tv1"
    dmsetup message "$pool" 0 "delete 1"
    after="$(python3 - "$MNT/f" <<'PY'
import os, sys, mmap, errno
buf = mmap.mmap(-1, 4096)
buf.write(b"z" * 4096)
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
    for i in range(64):
        os.pwrite(fd, buf, i * 2 * 4096)
    os.fsync(fd)
    os.close(fd)
    print("ok")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY
)" || true
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR' <<<"$out" && { log "fsck ($1): $(grep -m2 '^ERR' <<<"$out" | tr '\n' ' ')" >&2; out=ERR; } || out=clean
    dmsetup remove "$tv0"
    dmsetup remove "$pool"
    echo "nospc=$nospc refused=$refused stopped=$stopped enospc=$enospc after=$after fsck=$out"
}

get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (old verdict): $C"
[ "$(get refused "$R")" = 1 ] && [ "$(get refused "$C")" = 1 ] ||
    { fail "setup: no new metadata block was refused for space ($R | $C)"; ct_exit; }
pass "setup: a new metadata block was refused by the full pool"
[ "$(get stopped "$R")" = no ] && pass "1: the mount did not stop" || fail "1: the mount stopped over a full thin pool"
[ "$(get enospc "$R")" = 1 ] && pass "2: the write failed ENOSPC" || fail "2: the write did not fail ENOSPC"
[ "$(get after "$R")" = ok ] && pass "3: with space back, the same writes succeed without a remount" ||
    fail "3: with space back the writes failed ($(get after "$R"))"
[ "$(get fsck "$R")" = clean ] && pass "4: fsck: no ERR" || fail "4: fsck reports errors"
[ "$(get stopped "$C")" = yes ] && pass "control: the old verdict stopped the mount" ||
    fail "control: the old verdict did not stop the mount -- the suite does not reach the new-block write"
ct_exit
