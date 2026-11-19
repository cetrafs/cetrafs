#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a sync does not report success over held tree blocks it cannot reach
#
# sync_fs writes every held-back tree block (cetrafs_deferred_flush_all()),
# looking each listed inode up. An object a refresh unhashed while an fd
# still holds it -- a peer deleted the file and reused the number -- is
# not found, or the number's new file is, with an empty list: the walk
# skipped the set, met the same entry on every round until its bound ran
# out, and the sync returned success with the set still held (audit
# 2026-11-15 BL-23). It now fails, and the set is written when the
# object closes or is evicted.
#
# Staged on one node, nofilelock: a spilled file held open, an O_DIRECT
# edit of its leaf held back on that open object; the object unhashed
# (flush_all_unhash_ino, as the refresh does); then a sync.
#   setup: the edit was not on the device when the sync ran;
#   1. the sync failed, and said why.
#
# That set then stopped the walk: every held set after it stayed unwritten
# on every sync for as long as the file stayed open (audit F-73). A second
# file, made after the first, holds an edit too:
#   2. its edit is on the device after the failed sync;
#   3. the same past a first set whose WRITE failed (tree_flush_fail_once).
#
# Not reached here: an orphan batch failing (it ends the orphan rounds,
# the walk goes on), the fence check per round, the cursor's one wrap and
# a failed skip-list allocation -- each is read, not staged.
#
# DISCRIMINATION: flush_all_skip_unhashed=1 -- the sync succeeds;
# flush_all_stop_at_failure=1 -- the second file's edit stays held (2, 3).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in flush_all_skip_unhashed flush_all_stop_at_failure flush_all_unhash_ino hb_maint_delay_ms tree_flush_fail_once; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LP="$(ct_helper leaf_poke)"
MNT="$(ct_mnt swev)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set publish_root_ahead 1 # the staging stands on the old publish order (close_retry_orphans)
ct_param_set flush_all_skip_unhashed 0
ct_param_set flush_all_stop_at_failure 0
ct_param_set tree_flush_fail_once 0
ct_param_set flush_all_unhash_ino 0
ct_param_set hb_maint_delay_ms 0
ct_param_set hb_interval_secs 2

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

# <skip 0|1> <stop 0|1> <u|f> -> "held= rc= said= unwritten= other="
# u: the first file's object is unhashed; f: its flush fails (as a device error)
round() {
    local img dev f g ino gino mark pid held=0 after=0 other=0 rc=0 said=0
    img="$(ct_image 560 "swev$1$2$3")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    # nofilelock: with the lock on, a writer's own lock declines the
    # refresh that unhashes, so the object is never unhashed while open.
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    f="$MNT/img"
    fallocate -l $((4 << 20)) "$f"
    for i in $(seq 0 6); do dio_write "$f" $((i * 64)) "$(printf 'B%07d' $((i * 64)))"; done
    dio_write "$f" 448 B0000448 fsync
    ino="$(stat -c %i "$f")"
    # A second file, made after the first so its tree blocks sort after
    # them: a healthy held set the walk reaches only past the first's.
    g="$MNT/other"
    fallocate -l $((4 << 20)) "$g"
    for i in $(seq 0 6); do dio_write "$g" $((i * 64)) "$(printf 'G%07d' $((i * 64)))"; done
    dio_write "$g" 448 G0000448 fsync
    gino="$(stat -c %i "$g")"
    echo 30000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep 3 # a pass already past its delay ends; the next one waits
    # The edit, held back on an object that stays open.
    rm -f "$MNT.go"
    python3 -I - "$f" "$g" "$MNT.go" <<'PY' &
import mmap, os, sys, time
buf = mmap.mmap(-1, 4096)
buf.write(b"HELD0900" * 512)
fds = [os.open(p, os.O_RDWR | os.O_DIRECT) for p in sys.argv[1:3]]
for fd in fds:
    os.pwritev(fd, [buf], 900 * 4096)
while not os.path.exists(sys.argv[3]):
    time.sleep(0.1)
for fd in fds:
    os.close(fd)
PY
    pid=$!
    sleep 1
    # The unhash, as a refresh does to an object it finds deleted or
    # reused (inode.c): hard to stage with the object held open on one
    # node, so a test hook does it, and the walk is the sole path tested.
    "$LP" "$img" show "$ino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" || held=1
    [ "$3" = u ] && echo "$ino" >/sys/module/cetrafs/parameters/flush_all_unhash_ino
    "$LP" "$img" show "$gino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" && held=0
    echo "$1" >/sys/module/cetrafs/parameters/flush_all_skip_unhashed
    echo "$2" >/sys/module/cetrafs/parameters/flush_all_stop_at_failure
    mark="$(dmesg_mark)"
    [ "$3" = f ] && echo 1 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    sync -f "$MNT" 2>/dev/null || rc=$?
    [ "$3" = f ] && [ "$(cat /sys/module/cetrafs/parameters/tree_flush_fail_once)" = Y ] && held=0 # never consumed
    echo 0 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    if [ "$3" = u ]; then
        dmesg_since "$mark" | grep -q "deferred: ino=$ino .*holds tree blocks on an object no longer in the inode cache" && said=1
    else
        said=1
    fi
    "$LP" "$img" show "$ino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" || after=1
    "$LP" "$img" show "$gino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" && other=1
    touch "$MNT.go"
    wait "$pid" || true
    rm -f "$MNT.go"
    echo 0 >/sys/module/cetrafs/parameters/flush_all_skip_unhashed
    echo 0 >/sys/module/cetrafs/parameters/flush_all_stop_at_failure
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    umount "$MNT" || umount -l "$MNT"
    echo "held=$held rc=$rc said=$said unwritten=$after other=$other"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0 0 u)"
log "fails: $R"
C="$(round 1 0 u)"
log "control (skips): $C"
S="$(round 0 1 u)"
log "control (stops at it): $S"
F="$(round 0 0 f)"
log "a failed write: $F"
G="$(round 0 1 f)"
log "control (stops at the failure): $G"
for v in "$R" "$C" "$S" "$F" "$G"; do
    [ "$(get held "$v")" = 1 ] || { fail "setup: the edit was already on the device before the sync ($v)"; ct_exit; }
done
pass "setup: the edits were held (not on the device) when the sync ran, and an injected failure was consumed"
[ "$(get said "$R")" = 1 ] && [ "$(get rc "$R")" != 0 ] && pass "1: the sync failed, and said why" ||
    fail "1: the sync did not fail over the unreachable set ($R)"
[ "$(get rc "$C")" = 0 ] && [ "$(get unwritten "$C")" = 1 ] &&
    pass "control: skipping it, the sync reported success with the edit not on the device" ||
    fail "control: the sync failed anyway -- the suite does not reach the walk ($C)"
[ "$(get other "$R")" = 1 ] && pass "2: the other file's held edit was written past the unreachable set" ||
    fail "2: the other file's held edit is not on the device ($R)"
[ "$(get rc "$S")" != 0 ] && [ "$(get other "$S")" = 0 ] &&
    pass "control: stopping at the unreachable set, the other file's edit was left unwritten" ||
    fail "control: the other file's edit landed anyway -- the suite does not reach the walk past it ($S)"
[ "$(get rc "$F")" != 0 ] && [ "$(get unwritten "$F")" = 1 ] && [ "$(get other "$F")" = 1 ] &&
    pass "3: past a set whose write failed, the other file's edit was written, and the sync failed" ||
    fail "3: a failed write kept the other file's edit back, or the sync succeeded ($F)"
[ "$(get rc "$G")" != 0 ] && [ "$(get unwritten "$G")" = 1 ] && [ "$(get other "$G")" = 0 ] &&
    pass "control: stopping at the failed write, the other file's edit was left unwritten" ||
    fail "control: the other file's edit landed anyway -- the suite does not reach the failure branch ($G)"
ct_exit
