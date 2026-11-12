#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a killed writer's close waits for a journal slot instead of failing and keeping the lock
#
# A close is a durability boundary: the file's held-back tree blocks go
# out as one journal batch, which takes a slot for every block before
# writing any (cetrafs_journal_take_batch()). When every slot is in
# flight with a single writer the batch waits for one -- and since
# 46e9e39 it gave up with -EINTR if the caller had a fatal signal. The
# close of a KILLED writer is exactly such a caller: the tree flush
# failed ("extent-tree blocks not durable"), the close kept the lock and
# queued the release for the heartbeat, and the file -- a VM image whose
# process a host just killed -- stayed unopenable on every other node
# for up to a heartbeat interval (review of 46e9e39). The wait now runs
# to the end of an in-flight write.
#
# Staged: the close's batch finds every slot in flight for 4 s
# (journal_batch_noslot_ms -- eight stalled single writers did not
# reliably fill the journal); the writer, with conversions pending in a
# fallocated file, is SIGKILLed while its close waits (at exit the kill
# is already dequeued -- only a kill landing in the wait is seen); the
# heartbeat is at its slowest (30 s), so a release left to it is seen.
#
#  1. once a slot is free, the file's lock is gone at once and
#     nothing was "not durable"; the writes read back after a remount;
#  2. control (journal_batch_eintr=1, the old path): the close fails its
#     tree flush and the lock is still held once slots are free.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_batch_eintr journal_batch_noslot_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 1200 cks)"
MNT="$(ct_mnt cks)"
ct_track mnt "$MNT"
ct_param_set journal_batch_eintr 0
ct_param_set journal_batch_noslot_ms 0
ct_param_set hb_interval_secs 30
mode_of() { "$LPOKE" "$DEV" "$1" | sed -n 's/.*mode=\([0-9]*\).*/\1/p'; }

# <tag>: sets HELD (lock mode once slots were free), NOTDUR, LOST
run() {
    ct_mkfs "$DEV" -s 1G -z 1 -b 512 -J 2 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    python3 - "$MNT/img" <<'PY' &
import os, sys, random, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
os.posix_fallocate(fd, 0, 16 << 20)
os.fsync(fd)
random.seed(3)
for b in random.sample(range(0, (16 << 20) // 4096), 64):
    os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
open(sys.argv[1] + ".ready", "w").close()
while not os.path.exists(sys.argv[1] + ".go"):
    time.sleep(0.05)
os.close(fd) # waits for a slot; killed while it does
time.sleep(600)
PY
    local W=$!
    for _ in $(seq 1 100); do [ -e "$MNT/img.ready" ] && break; sleep 0.1; done
    [ -e "$MNT/img.ready" ] || { fail "$1: setup: the writer never got ready"; kill -9 "$W"; ct_exit; }
    INO="$(stat -c %i "$MNT/img")"
    [ "$(mode_of "$INO")" = 1 ] || { fail "$1: setup: the writer does not hold the file's lock"; kill -9 "$W"; ct_exit; }
    MARK="$(dmesg_mark)"
    ct_param_set journal_batch_noslot_ms 4000
    touch "$MNT/img.go"
    sleep 1 # the close is waiting for a slot
    kill -9 "$W"
    wait "$W" 2>/dev/null || true
    sleep 4 # past the 4 s with no slot
    [ "$(cat /sys/module/cetrafs/parameters/journal_batch_noslot_ms)" = 0 ] ||
        { fail "$1: setup: the close never reached the batch"; ct_exit; }
    HELD="$(mode_of "$INO")"
    NOTDUR=0
    dmesg_since "$MARK" | grep -q "ino=$INO extent-tree blocks not durable" && NOTDUR=1
    for _ in $(seq 1 40); do [ "$(mode_of "$INO")" = 0 ] && break; sleep 1; done # the heartbeat's retry
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    LOST="$(python3 - "$MNT/img" <<'PY'
import os, sys, random
fd = os.open(sys.argv[1], os.O_RDONLY)
random.seed(3)
print(sum(1 for b in random.sample(range(0, (16 << 20) // 4096), 64) if os.pread(fd, 8, b * 4096) != b"%08d" % b))
PY
)"
    ct_umount "$MNT"
    log "$1: lock mode once slots were free $HELD, tree flush failed $NOTDUR, $LOST writes lost"
}

# ------------------------------------------------------------------ 2
log "2: control -- the old path: the batch gives up on the fatal signal"
ct_param_set journal_batch_eintr 1
run control
ct_param_set journal_batch_eintr 0
[ "$NOTDUR" = 1 ] && [ "$HELD" = 1 ] &&
    pass "control: the killed writer's close failed its tree flush and the file stayed locked" ||
    fail "control: the old path did not show the fault (flush failed $NOTDUR, mode $HELD) -- the suite cannot tell the two apart"

# ------------------------------------------------------------------ 1
log "1: the killed writer's close waits for a slot"
run fix
[ "$NOTDUR" = 0 ] && pass "1: the close's tree flush succeeded" || fail "1: the close's tree flush failed"
[ "$HELD" = 0 ] && pass "1: the file's lock was gone as soon as the in-flight writes were" ||
    fail "1: the file is still locked (mode $HELD) after the in-flight writes ended"
[ "$LOST" = 0 ] && pass "1: every write reads back after a remount" || fail "1: $LOST writes lost"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
