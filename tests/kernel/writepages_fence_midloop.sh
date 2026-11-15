#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a writepages pass that outlives the lease writes nothing after it
#
# writepages asked the fence once, when it started, and then mapped and
# wrote every dirty page of the pass: an fsync over GiB of dirty data
# runs for minutes, and the pages after a lease ran out landed on blocks
# a peer had taken over by then -- silent guest-data corruption, fsck
# clean (audit 2026-11-15 B-17). writepages now goes a chunk (8 MiB) at
# a time and asks the fence before each; an O_DIRECT write asks it for
# every block it maps.
#
# A file of 16384 blocks is written and fsynced (every block mapped),
# then overwritten with a marker, buffered. wb_stall_ms holds the pass
# that writes it after two chunks, while the mount is stopped
# (shutdown=now, the state a lapsed lease leaves); then it goes on.
#   setup: the pass stalled and the mount stopped under it;
#   1. at most the chunks written before the stop carry the marker on
#      the device -- far fewer than 16384 blocks.
#
# DISCRIMINATION: fence_per_block_off=1 (the gate once per call, one
# mpage pass, stalled just after that gate): the whole file reaches the
# device.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/wb_stall_ms ] || { skip "wb_stall_ms is missing"; ct_exit; }
MNT="$(ct_mnt wfm)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0

# <old 0|1> -> "stalled=<0|1> stopped=<yes|no> marked=<n>"
round() {
    local img dev proc st stopped marked
    img="$(ct_image 560 "wfm$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    dd if=/dev/zero of="$MNT/f" bs=1M count=64 conv=fsync status=none
    # the writer keeps its fd: a last close flushes the file itself
    local t
    t="$(ct_tmp "wfm-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    python3 - "$MNT/f" "$t" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY)
b = b'WBFENCE!' * 512
for i in range(16384):
    os.pwrite(fd, b, i * 4096)
open(os.path.join(sys.argv[2], "w"), "w").close()
while not os.path.exists(os.path.join(sys.argv[2], "close")):
    time.sleep(0.05)
try:
    os.close(fd)
except OSError:
    pass
PY
    local wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    echo "$1" >/sys/module/cetrafs/parameters/fence_per_block_off
    echo $((2 - $1)) >/sys/module/cetrafs/parameters/wb_stall_after # the old pass: one call, stalled after its gate
    echo 4000 >/sys/module/cetrafs/parameters/wb_stall_ms
    sync -d "$MNT/f" 2>/dev/null &
    local spid=$! dl=$((SECONDS + 30))
    # the stall takes its value as it starts: stop the mount right then
    while [ "$(cat /sys/module/cetrafs/parameters/wb_stall_ms)" != 0 ] && [ "$SECONDS" -lt "$dl" ]; do sleep 0.01; done
    echo "shutdown=now" >"$proc/controls" 2>/dev/null || true
    wait "$spid" || true
    touch "$t/close"
    wait "$wpid" || true
    st="$(cat /sys/module/cetrafs/parameters/wb_stall_ms)"
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    echo 0 >/sys/module/cetrafs/parameters/wb_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/wb_stall_after
    echo 0 >/sys/module/cetrafs/parameters/fence_per_block_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    losetup -d "$dev" 2>/dev/null || true
    marked="$(python3 -I - "$img" <<'PY'
import sys
want = b'WBFENCE!' * 512
n = 0
with open(sys.argv[1], 'rb') as f:
    while True:
        b = f.read(4096)
        if not b:
            break
        n += b == want
print(n)
PY
)"
    echo "stalled=$([ "$st" = 0 ] && echo 1 || echo 0) stopped=$stopped marked=$marked"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (once per call): $C"
for x in "$R" "$C"; do
    [ "$(get stalled "$x")" = 1 ] && [ "$(get stopped "$x")" = yes ] ||
        { fail "setup: the pass did not stall or the mount did not stop ($x)"; ct_exit; }
done
pass "setup: the pass stalled mid-way and the mount stopped under it"
[ "$(get marked "$R")" -lt 8192 ] && pass "1: only $(get marked "$R") of 16384 blocks reached the device, the chunks written before the stop" ||
    fail "1: $(get marked "$R") of 16384 blocks reached the device -- the pass went on writing after the stop"
[ "$(get marked "$C")" -ge 16000 ] && pass "control: once per call, the whole pass ($(get marked "$C") blocks) landed after the stop" ||
    fail "control: only $(get marked "$C") blocks landed with the old gate -- the suite does not reach the window"
ct_exit
