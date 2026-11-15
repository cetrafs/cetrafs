#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a close finished by the heartbeat writes the file's orphaned tree blocks first
#
# A close whose boundary failed keeps its lock and is finished by the
# heartbeat, on a fresh iget. It queues only (ino, generation) -- it does
# not pin the inode -- so the inode can be evicted first, its held-back
# leaf moving to the mount's orphan list. The retry's own flush then
# found nothing, published the record and cleared the lock with the
# leaf still in memory, and the orphan batch wrote it later over
# whatever a peer had done with the file meanwhile (audit 2026-11-14 B-7).
# The retry now writes the inode's orphans before it publishes.
#
# Staged on a journaled volume: an O_DIRECT edit of an external leaf, a
# close whose flush fails (tree_flush_fail_once: the retry is queued),
# then tree flushes that write nothing (tree_flush_skip_all) so syncfs
# cleans the record and drop_caches evicts the inode -- the leaf is
# orphaned. The heartbeat's maintenance pass is held off until then.
#   setup: the close failed, the leaf was orphaned, the heartbeat finished the close;
#   1. when it did, the edit was on the device.
#
# DISCRIMINATION: retry_orphans_off=1: the close is finished with the
# leaf still only in memory.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_flush_skip_all tree_flush_fail_once retry_orphans_off hb_maint_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LP="$(ct_helper leaf_poke)"
MNT="$(ct_mnt cro)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set tree_flush_skip_all 0
# The state staged here -- an inode evicted with tree blocks still held
# -- needs the record publish that does not wait for them: a publish now
# writes the held set first, or keeps the device's root and the inode
# dirty, so nothing is left to evict (publish_root_after_tree.sh). The
# old order is what this suite's staging stands on.
ct_param_set publish_root_ahead 1
ct_param_set tree_flush_fail_once 0
ct_param_set retry_orphans_off 0
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

# <orphans_off 0|1> -> "failed=<0|1> orphaned=<n> finished=<0|1> ondev=<0|1>"
round() {
    local img dev f proc ino o0 o1 mark failed=0 finished=0 ondev=0
    img="$(ct_image 560 "cro$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    f="$MNT/img"
    fallocate -l $((4 << 20)) "$f"
    for i in $(seq 0 6); do dio_write "$f" $((i * 4)) "$(printf 'B%07d' $((i * 4)))"; done
    dio_write "$f" 28 B0000028 fsync
    ino="$(stat -c %i "$f")"
    echo "$1" >/sys/module/cetrafs/parameters/retry_orphans_off
    echo 8000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    o0="$(sed -n 's/^deferred_orphaned: //p' "$proc/info")"
    mark="$(dmesg_mark)"
    echo 1 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    dio_write "$f" 120 FIRST001
    echo 1 >/sys/module/cetrafs/parameters/tree_flush_skip_all
    dmesg_since "$mark" | grep -q "ino=$ino.*\(queued\|retry\|heartbeat\)" && failed=1
    sync -f "$MNT"
    echo 2 >/proc/sys/vm/drop_caches
    o1="$(sed -n 's/^deferred_orphaned: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    for _ in $(seq 1 60); do
        dmesg_since "$mark" | grep -q "lock release: ino=$ino close finished by the heartbeat" && { finished=1; break; }
        sleep 0.5
    done
    "$LP" "$img" show "$ino" | grep -q "^ent [0-9]* block=120 .* uninit=0$" && ondev=1
    echo 0 >/sys/module/cetrafs/parameters/tree_flush_skip_all
    echo 0 >/sys/module/cetrafs/parameters/retry_orphans_off
    ct_umount "$MNT"
    echo "failed=$failed orphaned=$((o1 - o0)) finished=$finished ondev=$ondev"
}
get() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "orphans first: $R"
C="$(round 1)"
log "control (orphans ignored): $C"
for v in "$R" "$C"; do
    [ "$(get orphaned "$v")" -gt 0 ] && [ "$(get finished "$v")" = 1 ] ||
        { fail "setup: the leaf was not orphaned before the heartbeat finished the close ($v)"; ct_exit; }
done
pass "setup: the close failed, its leaf was orphaned by an eviction, and the heartbeat finished the close"
[ "$(get ondev "$R")" = 1 ] && pass "1: when the close was finished, the edit was on the device" ||
    fail "1: the close was finished with the edit only in memory"
[ "$(get ondev "$C")" = 0 ] && pass "control: ignoring the orphans, the close was finished with the edit only in memory" ||
    fail "control: the edit was on the device anyway -- the suite does not reach the window"
ct_exit
