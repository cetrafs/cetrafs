#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a compare-and-write is not sent once the mount is stopped, however long its read took
#
# The CAS layer asked the fence at entry (and per retry), then flushed,
# read the record fresh -- a read that can wait out a path failover --
# built the swap and sent it. A lease that ran out in that read did not
# stop the swap: a last-writer-wins record publish stamped this node's
# stale extent root over the tree of the node HA restarted the VM on
# (audit 2026-11-15 B-19). The fence is now asked again right before the
# CAW, on every attempt.
#
# Needs a real CAW: a LIO loopback target over the image. TEST ONLY
# cas_stall_ino/cas_stall_ms hold the next swap on the file's record
# between its read and its CAW; the mount is stopped (shutdown=now)
# inside that hold.
#   setup: the swap stalled and the mount stopped under it;
#   1. the record on the device is byte for byte what it was before.
#
# DISCRIMINATION: cas_gate_last_off=1: the swap lands after the stop,
# the record changes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cas_gate_last_off cas_stall_ino cas_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt cgbc)"
ct_track mnt "$MNT"
ct_param_set cas_stall_ms 0
ct_param_set cas_stall_ino 0
WHY="$(ct_tmp cgbc-why)"

# <old 0|1> -> "stalled=<0|1> stopped=<yes|no> same=<0|1>"
round() {
    local img disk proc t ino h0 h1 st stopped
    img="$(ct_image 560 "cgbc$1")"
    disk="$(ct_lio_disks "$img" 1 2>"$WHY")" || { echo "nolio"; return; }
    ct_mkfs_small "$disk" >/dev/null
    ct_mount "$disk" "$MNT"
    proc="$(ct_procdir "$disk")"
    t="$(ct_tmp "cgbc-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    python3 - "$MNT/f" "$t" <<'PY' &
import os, sys, time
f, t = sys.argv[1:3]
fd = os.open(f, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(fd, b"a" * 4096, 0)
os.fsync(fd)
open(os.path.join(t, "w0"), "w").close()
while not os.path.exists(os.path.join(t, "go")):
    time.sleep(0.05)
try:
    os.pwrite(fd, b"b" * 4096 * 64, 4096)
    os.fsync(fd)
except OSError:
    pass
try:
    os.close(fd)
except OSError:
    pass
PY
    local wpid=$!
    while [ ! -e "$t/w0" ]; do sleep 0.05; done
    ino="$(stat -c %i "$MNT/f")"
    sync "$MNT" 2>/dev/null || true
    h0="$("$IPOKE" "$img" dump "$ino" | sha256sum | cut -c1-16)"
    echo "$1" >/sys/module/cetrafs/parameters/cas_gate_last_off
    echo 3000 >/sys/module/cetrafs/parameters/cas_stall_ms
    echo "$ino" >/sys/module/cetrafs/parameters/cas_stall_ino
    touch "$t/go"
    local dl=$((SECONDS + 30))
    while [ "$(cat /sys/module/cetrafs/parameters/cas_stall_ino)" != 0 ] && [ "$SECONDS" -lt "$dl" ]; do sleep 0.01; done
    st="$(cat /sys/module/cetrafs/parameters/cas_stall_ino)"
    echo "shutdown=now" >"$proc/controls" 2>/dev/null || true
    wait "$wpid" || true
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    echo 0 >/sys/module/cetrafs/parameters/cas_stall_ino
    echo 0 >/sys/module/cetrafs/parameters/cas_gate_last_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    h1="$("$IPOKE" "$img" dump "$ino" | sha256sum | cut -c1-16)"
    echo "stalled=$([ "$st" = 0 ] && echo 1 || echo 0) stopped=$stopped same=$([ "$h0" = "$h1" ] && echo 1 || echo 0)"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
[ "$R" = nolio ] && { skip "$(cat "$WHY")"; ct_exit; }
log "fixed: $R"
C="$(round 1)"
log "control (no gate before the CAW): $C"
for x in "$R" "$C"; do
    [ "$(get stalled "$x")" = 1 ] && [ "$(get stopped "$x")" = yes ] ||
        { fail "setup: the swap did not stall, or the mount did not stop ($x)"; ct_exit; }
done
pass "setup: the swap stalled between its read and its CAW, and the mount stopped"
[ "$(get same "$R")" = 1 ] && pass "1: the record on the device is unchanged -- the swap was not sent" ||
    fail "1: the record changed after the stop"
[ "$(get same "$C")" = 0 ] && pass "control: without the gate the swap landed after the stop" ||
    fail "control: the record did not change without the gate -- the suite does not reach the swap"
ct_exit
