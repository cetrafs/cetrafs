#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lock taken for nothing and not given back is retried, not forgotten
#
# A flock(LOCK_EX) that finds a peer still reading, and a defrag pass
# that finds the same, claimed the file's lock first and back out by
# giving it back. That give-back's result was dropped: if it failed, the
# lock stayed on the record of a node that keeps beating -- stale
# reclaim never touches it, no local holder will release it -- and every
# peer got ETXTBSY until this node opened and closed the file again.
#
# Now a failed give-back is queued for the heartbeat, like a close's.
#
# A: nofilelock, flock's back-out (the reader check made to fail).
# B: default mount, the background defrag pass's back-out (a live peer
#    holds the file open for read).
# C: default mount, a flock(LOCK_EX) resume that claimed and then failed
#    its re-read, with the writer still open and the clear failing
#    (flock_clear_fail_once).
# Each with the give-back failing once (lock_giveback_fail_once): the
# lock must be on the device right after, and gone a few beats later.
#
# DISCRIMINATION: with the give-back's result dropped, the lock is still
# on the device when the wait ends, in every round; round C also fails
# if the heartbeat retry skips a suspended inode.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in lock_giveback_fail_once flock_reader_check_fail_once auto_defrag_begin_delay_ms lock_ignore_readers; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
ct_param_set hb_interval_secs 2

# wait_clear <img> <ino> <label>: the lock is held now and must go.
wait_clear() {
    local d
    d="$("$LOCK_POKE" "$1" "$2")"
    grep -q 'mode=1' <<<"$d" || { fail "$3: setup: no lock was left on the device ($d)"; return; }
    [ "$(cat /sys/module/cetrafs/parameters/lock_giveback_fail_once)" = N ] ||
        { fail "$3: setup: the give-back never ran"; return; }
    for _ in $(seq 1 20); do
        grep -q 'mode=0' <<<"$("$LOCK_POKE" "$1" "$2")" && { pass "$3: the heartbeat gave the lock back"; return; }
        sleep 1
    done
    fail "$3: the lock is still on the device 20s later -- the failed give-back was forgotten ($("$LOCK_POKE" "$1" "$2"))"
}

# --- A: flock under nofilelock.
IMG="$(ct_image 560 gbflock)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt gbflock)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo image >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
sync
ct_param_set flock_reader_check_fail_once 1
ct_param_set lock_giveback_fail_once 1
RES="$(python3 - "$MNT/vm.img" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); r = "ok"
except OSError as e:
    r = "errno%d" % e.errno
print(r)
os.close(fd)
PY
)"
[ "$RES" != ok ] || fail "A: setup: LOCK_EX succeeded -- the reader check did not back it out"
wait_clear "$IMG" "$INO" "A (flock)"
ct_umount "$MNT"

# --- B: the background defrag pass under the default mount.
IMG="$(ct_image 560 gbdefrag)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt gbdefrag)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((${NODE:-0} + 1) % 4))
python3 - "$MNT" <<'PY'
import os, sys
v = os.open(sys.argv[1] + "/victim", os.O_WRONLY | os.O_CREAT, 0o644)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(6):
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
    os.pwrite(v, bytes([65 + i]) * 4096, i * 4096); os.fsync(v)
os.close(s); os.close(v)
PY
sync
INO="$(stat -c %i "$MNT/victim")"
# A live peer reading the file: planted after the mount (a loop device
# has no CAW, so the mount gate refuses a live peer) and kept beating.
"$NODE_POKE" "$IMG" "$PEER" 1 cc "$(date +%s)" >/dev/null
( while :; do "$NODE_POKE" "$IMG" "$PEER" --beat >/dev/null 2>&1 || true; sleep 1; done ) &
BEATER=$!
ct_track cmd "kill $BEATER"
"$LOCK_POKE" "$IMG" "$INO" --reader "$PEER" >/dev/null
# The trigger is a write-open + close, which the access rule refuses
# past a live reader; let it through so the pass gets queued.
ct_param_set lock_ignore_readers 1
ct_param_set auto_defrag_min_extents 2
ct_param_set auto_defrag_min_pct 0
ct_param_set lock_giveback_fail_once 1
ct_param_set auto_defrag 1
MARK="$(dmesg_mark)"
: >>"$MNT/victim"
for _ in $(seq 1 30); do
    dmesg_since "$MARK" | grep -q "ino=$INO defrag could not give the lock back" && break
    sleep 0.5
done
ct_param_set auto_defrag 0
dmesg_since "$MARK" | grep -q "ino=$INO defrag could not give the lock back" ||
    { fail "B: setup: the defrag pass never backed out ($(dmesg_since "$MARK" | grep -i defrag | tail -2))"; }
wait_clear "$IMG" "$INO" "B (defrag)"
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
ct_param_set lock_ignore_readers 0
ct_umount "$MNT"
"$NODE_POKE" "$DEV" "$PEER" 0 cc 0 >/dev/null

# --- C: a resume. A writer hands its lock over (flock LOCK_UN) and takes
# it back (LOCK_EX); the resume claims, its re-read fails, and the give
# -back fails too. The writer stays OPEN through the wait: the retry used
# to skip a suspended inode with a writer, and the writer's eventual
# close does not clear a suspended lock either -- nothing ever would.
[ -w /sys/module/cetrafs/parameters/lock_resume_reread_fail_once ] || { skip "C: lock_resume_reread_fail_once is missing"; ct_exit; }
IMG="$(ct_image 560 gbresume)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt gbresume)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo image >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
sync
GO="$(ct_tmp gbresume-go)"; rm -f "$GO"
RESF="$(ct_tmp gbresume-res)"
python3 - "$MNT/vm.img" "$GO" >"$RESF" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_UN)                 # suspend: the lock goes to NONE
open("/sys/module/cetrafs/parameters/lock_resume_reread_fail_once", "w").write("1")
open("/sys/module/cetrafs/parameters/flock_clear_fail_once", "w").write("1")
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); r = "ok"
except OSError as e:
    r = "errno%d" % e.errno
print(r, flush=True)
while not os.path.exists(sys.argv[2]):         # the writer stays open
    time.sleep(0.2)
os.close(fd)
PY
HOLDER=$!
for _ in $(seq 1 50); do [ -s "$RESF" ] && break; sleep 0.1; done
[ "$(cat "$RESF")" != ok ] || fail "C: setup: LOCK_EX succeeded -- the resume did not fail"
[ "$(cat /sys/module/cetrafs/parameters/lock_resume_reread_fail_once)" = N ] ||
    fail "C: setup: the resume never re-read the record"
[ "$(cat /sys/module/cetrafs/parameters/flock_clear_fail_once)" = N ] ||
    fail "C: setup: the resume never tried to give the lock back"
wait_clear "$IMG" "$INO" "C (resume, writer still open)"
touch "$GO"; wait "$HOLDER" || true
ct_umount "$MNT"
ct_exit
