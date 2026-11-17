#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an O_DIRECT write a full thin pool refuses fails ENOSPC, not EIO, so qemu pauses the guest
#
# The old O_DIRECT code (fs/direct-io.c) turns every failed bio into EIO,
# a thin pool's "no space" included, and qemu pauses a guest on ENOSPC
# but hands EIO to it: a full pool showed the guest I/O errors on this
# path (audit BM-15). The completion now asks the device again with
# blocks no file uses, and reports ENOSPC when that is refused for space
# too. Where it asks decides whether the answer means anything (F-57): a
# pool provisions whole chunks, so the probe goes in the middle of a free
# run, in a chunk nothing live shares, and a chunk the device took anyway
# (space freed without a discard) is discarded and the next group tried.
#
# Staged on a real dm-thin pool (error_if_no_space, 64 KiB chunks) over
# loop devices, the volume on one thin device and USED: a live 4 MiB
# file, the target fallocated while the pool has space (the filesystem's
# blocks, none of the pool's yet), and a 40 MiB image written and deleted
# -- freed without a discard, so still provisioned, right where the first
# free run begins. A second thin device then fills the pool. 4 KiB
# O_DIRECT writes into the fallocated range, one per pool chunk, until
# one fails.
#   setup: a write failed, and the probe ran;
#   setup: the first probe landed in the deleted image's provisioned
#          space and was discarded (discard_cmds moved);
#   1. the write failed ENOSPC;
#   2. the mount did not stop, and the live file reads back intact;
#   3. with space back (the filler deleted), the same writes succeed and
#      read back, without a remount;
#   4. fsck: no ERR.
#   5. the same through fio, libaio and io_uring (qemu's async paths).
#
# DISCRIMINATION: dio_nospc_probe_off=1 (the device not asked): 1 fails,
# the write fails EIO. space_probe_at_head=1 (the probe of 5dc0717: the
# head of a free run, no discard): 1 fails on this used volume, EIO.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dio_nospc_probe_off space_probe_at_head; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_thin_pool 2>/dev/null || true
grep -q thin-pool <(dmsetup targets) || { skip "no dm thin-pool target"; ct_exit; }
MNT="$(ct_mnt dtnospc)"
ct_track mnt "$MNT"
ct_param_set dio_nospc_probe_off 0
ct_param_set space_probe_at_head 0
ct_param_set scrub 0

# <mode fixed|off|head> <engine sync|libaio|io_uring>
#   -> "err=<errno|none> probes=<n> found=<n> discards=<n> live=<ok|damaged> stopped=<yes|no> after=<ok|errno> fsck=<clean|ERR>"
round() {
    local meta data pool tv0 tv1 dev proc out p0 f0 d0 live0
    meta="$(ct_loop "$(ct_image 16 "dtmeta$1$2")")"
    data="$(ct_loop "$(ct_image 400 "dtdata$1$2")")"
    dd if=/dev/zero of="$meta" bs=4096 count=1 conv=fsync status=none
    pool="cetra-dtp$$-$1$2"
    tv0="cetra-dtv$$-$1$2"
    tv1="cetra-dtf$$-$1$2"
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
    # used: live data, the target, then an image deleted without a discard
    dd if=/dev/urandom of="$MNT/live" bs=1M count=4 oflag=direct status=none
    fallocate -l 8M "$MNT/f"
    dd if=/dev/urandom of="$MNT/gone" bs=1M count=40 oflag=direct status=none
    sync
    rm "$MNT/gone"
    sync
    live0="$(md5sum <"$MNT/live")"
    [ "$1" = off ] && echo 1 >/sys/module/cetrafs/parameters/dio_nospc_probe_off
    [ "$1" = head ] && echo 1 >/sys/module/cetrafs/parameters/space_probe_at_head
    # the filler takes every free chunk of the pool
    dd if=/dev/zero of="/dev/mapper/$tv1" bs=1M oflag=direct status=none 2>/dev/null || true
    log "pool after the filler: $(dmsetup status "$pool" | awk '{print $6}')" >&2
    p0="$(sed -n 's/^dio_nospc_probes: //p' "$proc/info")"
    f0="$(sed -n 's/^dio_nospc_found: //p' "$proc/info")"
    d0="$(sed -n 's/^discard_cmds: //p' "$proc/info")"
    if [ "$2" = sync ]; then
        out="$(python3 - "$MNT/f" <<'PY'
import os, sys, mmap, errno
buf = mmap.mmap(-1, 4096)
buf.write(b"y" * 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
res = "none"
for i in range(128):                       # one block per 64 KiB pool chunk
    try:
        os.pwrite(fd, buf, i * 16 * 4096)
    except OSError as e:
        res = errno.errorcode.get(e.errno, str(e.errno))
        break
os.close(fd)
print(res)
PY
)" || true
    else
        # async, as qemu's aio=native / io_uring: the same stride, 4 in flight
        out="$(fio --name=dtn --filename="$MNT/f" --rw=write:60k --bs=4k --size=8M --direct=1 \
            --ioengine="$2" --iodepth=4 --output=/dev/null 2>&1 || true)"
        case "$out" in
        *"No space left on device"*) out=ENOSPC ;;
        *"Input/output error"*) out=EIO ;;
        *"error"*) out=OTHER ;;
        *) out=none ;;
        esac
    fi
    local probes found discards stopped after
    probes=$(($(sed -n 's/^dio_nospc_probes: //p' "$proc/info") - p0))
    found=$(($(sed -n 's/^dio_nospc_found: //p' "$proc/info") - f0))
    discards=$(($(sed -n 's/^discard_cmds: //p' "$proc/info") - d0))
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls" 2>/dev/null || echo yes)"
    echo 0 >/sys/module/cetrafs/parameters/dio_nospc_probe_off
    echo 0 >/sys/module/cetrafs/parameters/space_probe_at_head
    # the array gets space back: the filler goes
    dmsetup remove "$tv1"
    dmsetup message "$pool" 0 "delete 1"
    after="$(python3 - "$MNT/f" <<'PY'
import os, sys, mmap, errno
buf = mmap.mmap(-1, 4096)
buf.write(b"z" * 4096)
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
    for i in range(128):
        os.pwrite(fd, buf, i * 16 * 4096)
    os.fsync(fd)
    rb = mmap.mmap(-1, 4096)
    for i in range(128):
        os.preadv(fd, [rb], i * 16 * 4096)
        if rb[:] != b"z" * 4096:
            print("readback"); sys.exit(0)
    os.close(fd)
    print("ok")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY
)" || true
    local live=ok
    echo 3 >/proc/sys/vm/drop_caches
    [ "$(md5sum <"$MNT/live")" = "$live0" ] || live=damaged
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    out2="$(ct_fsck "$dev" 2>&1 || true)"
    local fsck=clean
    grep -qE '^ERR' <<<"$out2" && { log "fsck ($1): $(grep -m2 '^ERR' <<<"$out2" | tr '\n' ' ')" >&2; fsck=ERR; }
    dmsetup remove "$tv0"
    dmsetup remove "$pool"
    echo "err=$out probes=$probes found=$found discards=$discards live=$live stopped=$stopped after=$after fsck=$fsck"
}

get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round fixed sync)"
log "fixed: $R"
C="$(round off sync)"
log "control (device not asked): $C"
H="$(round head sync)"
log "control (the probe at a run's head, 5dc0717): $H"
[ "$(get err "$R")" != none ] && [ "$(get probes "$R")" -ge 1 ] ||
    { fail "setup: no O_DIRECT write failed, or the probe never ran ($R)"; ct_exit; }
pass "setup: an O_DIRECT write into the full pool failed and the device was asked"
[ "$(get discards "$R")" -ge 1 ] && [ "$(get probes "$R")" -ge 2 ] &&
    pass "setup: a probe landed in provisioned free space, was discarded, and the next group was asked" ||
    fail "setup: no probe met provisioned free space ($R) -- the suite does not stage F-57's case"
[ "$(get err "$R")" = ENOSPC ] && [ "$(get found "$R")" -ge 1 ] && pass "1: the write failed ENOSPC" ||
    fail "1: the write failed $(get err "$R"), not ENOSPC ($R)"
[ "$(get stopped "$R")" = no ] && pass "2: the mount did not stop" || fail "2: the mount stopped"
[ "$(get live "$R")" = ok ] && pass "2: the live file beside the probed run reads back intact" ||
    fail "2: the live file was damaged"
[ "$(get after "$R")" = ok ] && pass "3: with space back, the same writes succeed and read back" ||
    fail "3: with space back: $(get after "$R")"
[ "$(get fsck "$R")" = clean ] && pass "4: fsck: no ERR" || fail "4: fsck reports errors"
[ "$(get err "$C")" = EIO ] && pass "control: with the device not asked, the write fails EIO" ||
    fail "control: with the probe off the write failed $(get err "$C") -- the suite does not reach the legacy path's EIO"
[ "$(get err "$H")" = EIO ] && [ "$(get probes "$H")" -ge 1 ] &&
    pass "control: the probe at a run's head is taken by provisioned space -- EIO on a used volume (F-57)" ||
    fail "control: the head probe answered $(get err "$H") ($H) -- the volume is not used enough to tell"

# 5. the same through async O_DIRECT, as qemu submits it (aio=native,
# io_uring): an allocating write's completion is deferred to a workqueue,
# where the probe runs.
if command -v fio >/dev/null; then
    for eng in libaio io_uring; do
        fio --enghelp 2>/dev/null | grep -qx "[[:space:]]*$eng" || { log "5: fio has no $eng engine"; continue; }
        RA="$(round fixed "$eng")"
        log "5 ($eng): $RA"
        [ "$(get err "$RA")" = ENOSPC ] && [ "$(get found "$RA")" -ge 1 ] &&
            pass "5: through $eng the write failed ENOSPC" ||
            fail "5: through $eng the write failed $(get err "$RA") ($RA)"
        [ "$(get after "$RA")" = ok ] && [ "$(get fsck "$RA")" = clean ] ||
            fail "5: through $eng: after=$(get after "$RA") fsck=$(get fsck "$RA")"
    done
    CA="$(round off libaio)"
    log "5 control (libaio, device not asked): $CA"
    [ "$(get err "$CA")" = EIO ] && pass "5 control: through libaio with the probe off, EIO" ||
        fail "5 control: through libaio with the probe off: $(get err "$CA") -- fio's error is not read"
else
    log "5: no fio -- the async path is not covered here"
fi
ct_exit
