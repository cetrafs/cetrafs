#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# O_DIRECT writes a full thin pool refuses fail ENOSPC, not EIO -- every one of them -- so qemu pauses the guest
#
# The old O_DIRECT code (fs/direct-io.c) turns every failed bio into EIO,
# a thin pool's "no space" included, and qemu pauses a guest on ENOSPC
# but hands EIO to it (audit BM-15). The completion now asks the device
# with blocks no file uses (cetrafs_discard_space_probe()):
#  - where (F-57): whole free thin chunks in a claimed run, not the head
#    of a run, which shares a chunk with live data;
#  - what a taken write means (F-59): space freed without a discard is
#    provisioned, and the probe's own discards hand chunks back, so no
#    probe write follows its own discard before the verdict, and the next
#    group writes as many more chunks as were handed back;
#  - who asks (F-58): a full pool fails every write in flight at once;
#    one probe runs and every failure that waited takes its answer, and a
#    FITRIM in progress lets the probe in between its runs.
#
# Staged on a real dm-thin pool (error_if_no_space, 64 KiB chunks) over
# loop devices. "used": a live 4 MiB file, the target fallocated while
# the pool has space, and a 40 MiB image written and deleted without a
# discard -- still provisioned, where the first free run begins. Then a
# second thin device fills the pool, and O_DIRECT writes go into the
# fallocated range: one at a time, one per pool chunk, until one fails
# ("one"), or 32 at once from 32 threads ("many").
#   setup: a write failed and the device was asked; the first probe met
#          provisioned free space and its chunks were discarded;
#   1. the write failed ENOSPC;
#   2. the mount did not stop, and the live file reads back intact;
#   3. with space back (the filler deleted), the same writes succeed and
#      read back, without a remount;
#   4. fsck: no ERR;
#   5. the same through fio, libaio and io_uring (qemu's async paths);
#   6. 32 writes failing at once, the probe as slow as on a SAN
#      (space_probe_stall_ms): all 32 ENOSPC (F-58);
#   7. the same while a FITRIM holds the trim mutex, stalled inside a run
#      (trim_discard_stall_ms): all ENOSPC (F-58);
#   8. the probe's discards committed at once (space_probe_flush, as a
#      guest flush commits a dm-thin pool), so the pool can hand them
#      straight back: still ENOSPC (F-59).
#
# DISCRIMINATION: dio_nospc_probe_off=1: 1 fails, EIO.
# space_probe_at_head=1 (5dc0717's placement): 1 fails on the used
# volume, EIO. space_probe_unshared=1 (8e0f890's trylocks): 6 and 7 see
# EIO. space_probe_owed_off=1: 8 fails, EIO.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
KNOBS="dio_nospc_probe_off space_probe_at_head space_probe_unshared space_probe_owed_off space_probe_flush space_probe_stall_ms trim_discard_stall_ms"
for k in $KNOBS; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
command -v dmsetup >/dev/null || { skip "dmsetup is missing"; ct_exit; }
modprobe dm_thin_pool 2>/dev/null || true
grep -q thin-pool <(dmsetup targets) || { skip "no dm thin-pool target"; ct_exit; }
MNT="$(ct_mnt dtnospc)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
for k in $KNOBS; do ct_param_set "$k" 0; done
ct_param_set scrub 0

# <knobs k=v,...|-> <writer one|many|libaio|io_uring> <used 0|1> <fitrim 0|1> <tag>
#   -> "err=<ENOSPC|EIO|none|MIXED-<enospc>-<other>> probes=<n> found=<n> discards=<n>
#       live=<ok|damaged> stopped=<yes|no> after=<ok|errno> fsck=<clean|ERR>"
round() {
    local knobs=$1 writer=$2 used=$3 fitrim=$4 tag=$5
    local meta data pool tv0 tv1 dev proc out p0 f0 d0 live0="" tp=""
    meta="$(ct_loop "$(ct_image 16 "dtmeta$tag")")"
    data="$(ct_loop "$(ct_image 400 "dtdata$tag")")"
    dd if=/dev/zero of="$meta" bs=4096 count=1 conv=fsync status=none
    pool="cetra-dtp$$-$tag"
    tv0="cetra-dtv$$-$tag"
    tv1="cetra-dtf$$-$tag"
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
    dd if=/dev/urandom of="$MNT/live" bs=1M count=4 oflag=direct status=none
    fallocate -l 8M "$MNT/f"
    if [ "$used" = 1 ]; then
        # an image deleted without a discard: provisioned, and free
        dd if=/dev/urandom of="$MNT/gone" bs=1M count=40 oflag=direct status=none
        sync
        rm "$MNT/gone"
    fi
    sync
    live0="$(md5sum <"$MNT/live")"
    # the filler takes every free chunk of the pool
    dd if=/dev/zero of="/dev/mapper/$tv1" bs=1M oflag=direct status=none 2>/dev/null || true
    log "pool after the filler ($tag): $(dmsetup status "$pool" | awk '{print $6}')" >&2
    if [ "$knobs" != - ]; then
        local kv
        for kv in ${knobs//,/ }; do echo "${kv#*=}" >"$P/${kv%%=*}"; done
    fi
    if [ "$fitrim" = 1 ]; then
        # a FITRIM holding the trim mutex, stalled inside its first run
        echo 3000 >"$P/trim_discard_stall_ms"
        fstrim "$MNT" >/dev/null 2>&1 &
        tp=$!
        sleep 0.5
    fi
    p0="$(sed -n 's/^dio_nospc_probes: //p' "$proc/info")"
    f0="$(sed -n 's/^dio_nospc_found: //p' "$proc/info")"
    d0="$(sed -n 's/^discard_cmds: //p' "$proc/info")"
    case "$writer" in
    one)
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
        ;;
    many)
        out="$(python3 - "$MNT/f" <<'PY'
import os, sys, mmap, errno, threading
N = 32
go = threading.Barrier(N)
res = [None] * N
def w(i):
    buf = mmap.mmap(-1, 4096)
    buf.write(b"m" * 4096)
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
    go.wait()
    try:
        os.pwrite(fd, buf, (64 + i) * 16 * 4096)   # 32 chunks, none written before
        res[i] = "ok"
    except OSError as e:
        res[i] = errno.errorcode.get(e.errno, str(e.errno))
    os.close(fd)
t = [threading.Thread(target=w, args=(i,)) for i in range(N)]
[x.start() for x in t]
[x.join() for x in t]
nos = res.count("ENOSPC")
if nos == N:
    print("ENOSPC")
elif res.count("EIO") == N:
    print("EIO")
elif res.count("ok") == N:
    print("none")
else:
    print("MIXED-%d-%d" % (nos, N - nos))
PY
)" || true
        ;;
    *)
        # async, as qemu's aio=native / io_uring: the same stride, 4 in flight
        out="$(fio --name=dtn --filename="$MNT/f" --rw=write:60k --bs=4k --size=8M --direct=1 \
            --ioengine="$writer" --iodepth=4 --output=/dev/null 2>&1 || true)"
        case "$out" in
        *"No space left on device"*) out=ENOSPC ;;
        *"Input/output error"*) out=EIO ;;
        *"error"*) out=OTHER ;;
        *) out=none ;;
        esac
        ;;
    esac
    if [ -n "$tp" ]; then
        echo 0 >"$P/trim_discard_stall_ms"
        wait "$tp" || true
    fi
    local probes found discards stopped after live=ok
    probes=$(($(sed -n 's/^dio_nospc_probes: //p' "$proc/info") - p0))
    found=$(($(sed -n 's/^dio_nospc_found: //p' "$proc/info") - f0))
    discards=$(($(sed -n 's/^discard_cmds: //p' "$proc/info") - d0))
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls" 2>/dev/null || echo yes)"
    for k in $KNOBS; do echo 0 >"$P/$k"; done
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
    echo 3 >/proc/sys/vm/drop_caches
    [ "$(md5sum <"$MNT/live")" = "$live0" ] || live=damaged
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    local out2 fsck=clean
    out2="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR' <<<"$out2" && { log "fsck ($tag): $(grep -m2 '^ERR' <<<"$out2" | tr '\n' ' ')" >&2; fsck=ERR; }
    dmsetup remove "$tv0"
    dmsetup remove "$pool"
    echo "err=$out probes=$probes found=$found discards=$discards live=$live stopped=$stopped after=$after fsck=$fsck"
}

get() { sed -n "s/.*$1=\([0-9a-zA-Z_-]*\).*/\1/p" <<<"$2"; }
sound() { # <tag> <result>: 2, 3, 4 for any round
    [ "$(get stopped "$2")" = no ] && [ "$(get live "$2")" = ok ] && [ "$(get after "$2")" = ok ] &&
        [ "$(get fsck "$2")" = clean ] ||
        fail "$1: stopped=$(get stopped "$2") live=$(get live "$2") after=$(get after "$2") fsck=$(get fsck "$2")"
}

R="$(round - one 1 0 fx)"
log "fixed: $R"
[ "$(get err "$R")" != none ] && [ "$(get probes "$R")" -ge 1 ] ||
    { fail "setup: no O_DIRECT write failed, or the probe never ran ($R)"; ct_exit; }
pass "setup: an O_DIRECT write into the full pool failed and the device was asked"
[ "$(get discards "$R")" -ge 1 ] && [ "$(get probes "$R")" -ge 2 ] &&
    pass "setup: the first probe met provisioned free space, and its chunks were discarded" ||
    fail "setup: no probe met provisioned free space ($R) -- the suite does not stage F-57's case"
[ "$(get err "$R")" = ENOSPC ] && [ "$(get found "$R")" -ge 1 ] && pass "1: the write failed ENOSPC" ||
    fail "1: the write failed $(get err "$R"), not ENOSPC ($R)"
[ "$(get stopped "$R")" = no ] && pass "2: the mount did not stop" || fail "2: the mount stopped"
[ "$(get live "$R")" = ok ] && pass "2: the live file beside the probed run reads back intact" ||
    fail "2: the live file was damaged"
[ "$(get after "$R")" = ok ] && pass "3: with space back, the same writes succeed and read back" ||
    fail "3: with space back: $(get after "$R")"
[ "$(get fsck "$R")" = clean ] && pass "4: fsck: no ERR" || fail "4: fsck reports errors"

C="$(round dio_nospc_probe_off=1 one 1 0 off)"
log "control (device not asked): $C"
[ "$(get err "$C")" = EIO ] && pass "control: with the device not asked, the write fails EIO" ||
    fail "control: with the probe off the write failed $(get err "$C") -- the suite does not reach the legacy path's EIO"
H="$(round space_probe_at_head=1 one 1 0 hd)"
log "control (the probe at a run's head, 5dc0717): $H"
[ "$(get err "$H")" = EIO ] && [ "$(get probes "$H")" -ge 1 ] &&
    pass "control: the probe at a run's head is taken by provisioned space -- EIO on a used volume (F-57)" ||
    fail "control: the head probe answered $(get err "$H") ($H) -- the volume is not used enough to tell"

# 5. async
if command -v fio >/dev/null; then
    for eng in libaio io_uring; do
        fio --enghelp 2>/dev/null | grep -qx "[[:space:]]*$eng" || { log "5: fio has no $eng engine"; continue; }
        RA="$(round - "$eng" 1 0 "a$eng")"
        log "5 ($eng): $RA"
        [ "$(get err "$RA")" = ENOSPC ] && [ "$(get found "$RA")" -ge 1 ] &&
            pass "5: through $eng the write failed ENOSPC" ||
            fail "5: through $eng the write failed $(get err "$RA") ($RA)"
        sound "5 ($eng)" "$RA"
    done
else
    log "5: no fio -- the async path is not covered here"
fi

# 6. many at once. On this rig a probe takes microseconds and the 32
# failures arrive one after another; on a SAN each probe write is tens of
# milliseconds. space_probe_stall_ms gives the probe that length, so the
# failures meet it running -- in the round and in its control alike.
M="$(round space_probe_stall_ms=500 many 1 0 mn)"
log "6: 32 at once: $M"
[ "$(get err "$M")" = ENOSPC ] && pass "6: 32 writes failing at once all failed ENOSPC ($(get probes "$M") probe writes)" ||
    fail "6: 32 writes failing at once: $(get err "$M") ($M)"
sound 6 "$M"
MC="$(round space_probe_stall_ms=500,space_probe_unshared=1 many 1 0 mnc)"
log "6 control (8e0f890's trylocks): $MC"
# the probe ran (some ENOSPC) and the others found it busy (some EIO)
case "$(get err "$MC")" in
MIXED-[1-9]*-[1-9]*) pass "6 control: with the probe unshared, one probe answered and the rest got EIO ($(get err "$MC")) -- F-58 reproduced" ;;
*) fail "6 control: unshared, the 32 got $(get err "$MC") ($MC) -- not one probe and the rest EIO" ;;
esac

# 7. under a FITRIM (a volume with no provisioned free space: the FITRIM
# must not give the pool real space back)
T="$(round - many 0 1 tr)"
log "7: 32 at once under a FITRIM: $T"
[ "$(get err "$T")" = ENOSPC ] && pass "7: under a FITRIM in progress, all 32 failed ENOSPC" ||
    fail "7: under a FITRIM in progress: $(get err "$T") ($T)"
sound 7 "$T"
TC="$(round space_probe_unshared=1 many 0 1 trc)"
log "7 control (8e0f890's trylocks): $TC"
# none could probe: the FITRIM held the mutex
[ "$(get err "$TC")" = EIO ] && [ "$(get probes "$TC")" = 0 ] &&
    pass "7 control: with the probe unshared, the FITRIM's mutex left all 32 EIO, no probe run" ||
    fail "7 control: unshared under a FITRIM: $(get err "$TC") ($TC) -- the FITRIM did not hold the mutex"

# 8. the probe's own discards handed straight back
F="$(round space_probe_flush=1 one 1 0 fl)"
log "8: discards committed at once: $F"
[ "$(get err "$F")" = ENOSPC ] && [ "$(get discards "$F")" -ge 1 ] &&
    pass "8: with its discards committed at once, the probe still answers ENOSPC" ||
    fail "8: with its discards committed at once: $(get err "$F") ($F)"
sound 8 "$F"
FC="$(round space_probe_flush=1,space_probe_owed_off=1 one 1 0 flc)"
log "8 control (no more chunks than the discards gave back): $FC"
[ "$(get err "$FC")" = EIO ] && pass "8 control: counting nothing for its own discards, the probe answers EIO -- F-59 reproduced" ||
    fail "8 control: owed off: $(get err "$FC") ($FC) -- the pool did not hand the discarded chunks back"
ct_exit
