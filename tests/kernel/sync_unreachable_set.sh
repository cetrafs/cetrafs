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
# DISCRIMINATION: flush_all_skip_unhashed=1 -- the sync succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in flush_all_skip_unhashed flush_all_unhash_ino hb_maint_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LP="$(ct_helper leaf_poke)"
MNT="$(ct_mnt swev)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set publish_root_ahead 1 # the staging stands on the old publish order (close_retry_orphans)
ct_param_set flush_all_skip_unhashed 0
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

# <skip 0|1> -> "held= rc= said= unwritten="
round() {
    local img dev f ino mark pid held=0 after=0 rc=0 said=0
    img="$(ct_image 560 "swev$1")"
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
    echo 30000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep 3 # a pass already past its delay ends; the next one waits
    # The edit, held back on an object that stays open.
    rm -f "$MNT.go"
    python3 -I - "$f" "$MNT.go" <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(b"HELD0900" * 512)
os.pwritev(fd, [buf], 900 * 4096)
while not os.path.exists(sys.argv[2]):
    time.sleep(0.1)
os.close(fd)
PY
    pid=$!
    sleep 1
    # The unhash, as a refresh does to an object it finds deleted or
    # reused (inode.c): hard to stage with the object held open on one
    # node, so a test hook does it, and the walk is the sole path tested.
    "$LP" "$img" show "$ino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" || held=1
    echo "$ino" >/sys/module/cetrafs/parameters/flush_all_unhash_ino
    echo "$1" >/sys/module/cetrafs/parameters/flush_all_skip_unhashed
    mark="$(dmesg_mark)"
    sync -f "$MNT" 2>/dev/null || rc=$?
    dmesg_since "$mark" | grep -q "deferred: ino=$ino .*holds tree blocks on an object no longer in the inode cache" && said=1
    "$LP" "$img" show "$ino" | grep -q "^ent [0-9]* block=900 .* uninit=0$" || after=1
    touch "$MNT.go"
    wait "$pid" || true
    rm -f "$MNT.go"
    echo 0 >/sys/module/cetrafs/parameters/flush_all_skip_unhashed
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    umount "$MNT" || umount -l "$MNT"
    echo "held=$held rc=$rc said=$said unwritten=$after"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fails: $R"
C="$(round 1)"
log "control (skips): $C"
for v in "$R" "$C"; do
    [ "$(get held "$v")" = 1 ] || { fail "setup: the edit was already on the device before the sync ($v)"; ct_exit; }
done
pass "setup: the edit was held (not on the device) when the sync ran"
[ "$(get said "$R")" = 1 ] && [ "$(get rc "$R")" != 0 ] && pass "1: the sync failed, and said why" ||
    fail "1: the sync did not fail over the unreachable set ($R)"
[ "$(get rc "$C")" = 0 ] && [ "$(get unwritten "$C")" = 1 ] &&
    pass "control: skipping it, the sync reported success with the edit not on the device" ||
    fail "control: the sync failed anyway -- the suite does not reach the walk ($C)"
ct_exit
