#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag step stopped by a fence writes none of its copies
#
# The mover asked the fence once per batch, before reading up to 128
# source blocks forced-fresh, then wrote the copies straight to the
# destination run. A stall in that read outlasting the stale window let
# a peer take the group, recount it from a device without the
# destination's bits, and hand the run to a growing file -- which the
# copies then overwrote (audit 2026-11-15 B-32). The fence is now asked
# again before each destination write.
#
# A file of 64 extents of 16 blocks, each block its own pattern, is
# defragmented by hand; defrag_copy_stall_ms holds the first batch
# between its read and its writes, and the mount is stopped
# (shutdown=now) inside the hold.
#   setup: the batch stalled and the mount stopped;
#   1. every block pattern is on the device exactly once -- no copy
#      was written.
#
# DISCRIMINATION: defrag_copy_gate_off=1: the batch's copies land, the
# patterns are on the device twice. With meta_gate_unlocked_only=1 too:
# every buffer write asks the fence again under its lock (BM-24, 72d3481),
# a second gate behind this one, and with it on the control could not
# fail -- this suite's gate must be the sole one in its way.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the defragmenter, which nofilelock disables (nofilelock_no_defrag.sh)"
[ -w /sys/module/cetrafs/parameters/defrag_copy_stall_ms ] || { skip "defrag_copy_stall_ms is missing"; ct_exit; }
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_copy_stall_ms 0
ct_param_set meta_gate_unlocked_only 0
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dvf)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters

# <old 0|1> -> "stalled=<0|1> stopped=<yes|no> copies=<n>"
round() {
    local img dev proc st stopped copies
    img="$(ct_image 560 "dvf$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    python3 - "$MNT/f" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[1] + ".fill", os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(64):
    os.pwrite(a, b"".join((b"DVF%08d" % (i * 16 + j)) * 372 + b"\0" * 4 for j in range(16)), i * 16 * 4096); os.fsync(a)
    os.pwrite(b, b"x" * 4096, i * 4096); os.fsync(b)
os.close(a); os.close(b)
PY
    sync
    echo "$1" >$P/defrag_copy_gate_off
    echo "$1" >$P/meta_gate_unlocked_only
    echo 4000 >$P/defrag_copy_stall_ms
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 &
    local dpid=$! dl=$((SECONDS + 30))
    while [ "$(cat $P/defrag_copy_stall_ms)" != 0 ] && [ "$SECONDS" -lt "$dl" ]; do sleep 0.01; done
    st="$(cat $P/defrag_copy_stall_ms)"
    echo "shutdown=now" >"$proc/controls" 2>/dev/null || true
    wait "$dpid" || true
    stopped="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    echo 0 >$P/defrag_copy_gate_off
    echo 0 >$P/meta_gate_unlocked_only
    echo 0 >$P/defrag_copy_stall_ms
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    losetup -d "$dev" 2>/dev/null || true
    copies="$(python3 -I - "$img" <<'PY'
import sys
n = 0
with open(sys.argv[1], 'rb') as f:
    while True:
        b = f.read(4096)
        if not b:
            break
        n += b[:3] == b"DVF" and b[11:14] == b"DVF"
print(n)
PY
)"
    echo "stalled=$([ "$st" = 0 ] && echo 1 || echo 0) stopped=$stopped copies=$copies"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (no gate before the writes): $C"
for x in "$R" "$C"; do
    [ "$(get stalled "$x")" = 1 ] && [ "$(get stopped "$x")" = yes ] ||
        { fail "setup: the batch did not stall or the mount did not stop ($x)"; ct_exit; }
done
pass "setup: the first batch stalled between its read and its writes, and the mount stopped"
[ "$(get copies "$R")" = 1024 ] && pass "1: each of the 1024 blocks is on the device once -- no copy written" ||
    fail "1: $(get copies "$R") pattern blocks on the device, not 1024"
[ "$(get copies "$C")" -gt 1024 ] && pass "control: without the gate the batch's copies landed ($(get copies "$C") blocks)" ||
    fail "control: no copy landed without the gate ($(get copies "$C")) -- the suite does not reach the writes"
ct_exit
