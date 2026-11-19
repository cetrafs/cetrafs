#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every discard goes out after a cache flush, never behind writes still volatile
#
# A discard takes effect on the device at once. What let the blocks go
# -- the record publish of a punch or an unlink, the frees, a trim's
# hold, a hand-back's pending flag -- were writes that had only
# COMPLETED: on a volatile cache a power cut can lose them while the
# UNMAP stands, and the record the device keeps names blocks that now
# read as zeros (audit 2026-11-15 BC-42). cetrafs_discard_issue() now
# flushes the cache ahead of every discard.
#
# A loop device completes every write durably and in order, so no mount
# or fsck sees this; the order is read out of a dm-log-writes recording.
# From a mark placed after setup: for every DISCARD, were writes issued
# since the last FLUSH (and not FUA) still pending? It must be none.
# The workload covers each issuer: an -o discard punch (the inline
# queue), an unlink, then FITRIM.
#
# DISCRIMINATION: built in. discard_flush_off sends the discards
# without the flush, and the same recording must then show discards
# behind pending writes; if it does not, this suite proves nothing.
#
# Opt-in like the rest of tests/crash (make check-crash).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/discard_flush_off ] || { skip "discard_flush_off is missing"; ct_exit; }

REPLAY="$CT_BUILD/replay-log"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set discard_flush_off 0
ct_param_set inline_discard_delay_ms 200

SZ_MB=560
SECTORS=$((SZ_MB * 1024 * 1024 / 512))
MNT="$(ct_mnt dflush)"
ct_track mnt "$MNT"

# record <flush_off>: the workload through dm-log-writes; prints the
# order check's answer.
record() {
    local off="$1" data log dm lw proc i b0
    data="$(ct_loop "$(ct_image "$SZ_MB" "dflush-d$off")")"
    log="$(ct_loop "$(ct_image 1024 "dflush-l$off")")"
    dm="dflush_${off}_$$"
    dmsetup create "$dm" --table "0 $SECTORS log-writes $data $log"
    ct_track dm "$dm"
    lw="/dev/mapper/$dm"
    ct_mkfs "$lw" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    CT_MOUNT_OPTS=discard ct_mount "$lw" "$MNT"
    proc="$(ct_procdir "$lw")"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=16 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/g" bs=1M count=8 conv=fsync status=none
    sync
    sleep 1 # what the writes gave back is worked off before the mark
    ct_param_set discard_flush_off "$off"
    dmsetup message "$dm" 0 mark work
    b0="$(sed -n 's/^discard_cmds: //p' "$proc/info")"
    fallocate -p -o $((4 << 20)) -l $((8 << 20)) "$MNT/f" # inline queue
    rm "$MNT/g"
    sync
    for i in $(seq 1 30); do
        [ "$(sed -n 's/^discard_cmds: //p' "$proc/info")" -gt "$b0" ] && break
        sleep 0.2
    done
    sleep 0.5
    fstrim "$MNT" 2>/dev/null || true
    ct_param_set discard_flush_off 0
    ct_umount "$MNT"
    dmsetup remove "$dm"
    blockdev --flushbufs "$log"
    "$REPLAY" --log "$log" --check-discards-flushed work || true
}

get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

OUT="$(record 1)"
log "control (no flush ahead): $OUT"
[ "${OUT%% *}" != "$OUT" ] && [ "$(get discards "$OUT")" -gt 0 ] ||
    { fail "setup: the recording holds no discard after the mark ($OUT) -- nothing was trimmed"; ct_exit; }
[ "$(get unflushed "$OUT")" -gt 0 ] &&
    pass "control: without the flush, discards went out behind writes still volatile ($OUT)" ||
    { fail "setup: with the flush off no discard was behind a pending write ($OUT) -- this suite proves nothing"; ct_exit; }

OUT="$(record 0)"
log "as shipped: $OUT"
[ "$(get discards "$OUT")" -gt 0 ] || { fail "setup: no discard after the mark ($OUT)"; ct_exit; }
[ "$(get unflushed "$OUT")" = 0 ] && pass "every discard went out after a flush, nothing volatile behind it ($OUT)" ||
    fail "discards went out with writes still volatile: $OUT"
ct_exit
