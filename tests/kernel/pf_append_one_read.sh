#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a foreign-free append reads its queue a chunk per wait, not a block per round trip
#
# Each append to a peer's pending-free queue scans it from block 0 (the
# drain's quiet probe needs appends to fill from the front), reading every
# block ahead of the first one with room. It read them one device round
# trip each, so N separate frees -- a guest discarding one range at a
# time, a punch per extent -- cost O(N * full blocks): quadratic within
# one drain interval (audit 2026-11-14 P10). The planning read now takes
# CETRAFS_PF_APPEND_CHUNK (8) blocks per wait.
#
# Staged on one node with pf_force_foreign (every free goes through the
# queue) and a long heartbeat, so no drain empties the queue meanwhile: a
# file of N one-block extents is punched one extent per call.
#   setup: every punch appended (N appends), and the queue grew past one
#          chunk -- or the front was never full and nothing is measured;
#   1. the appends' planning reads stay within ~1 request per append plus
#      one per chunk the queue grew to;
#   2. after a remount the queue is applied: free space is back, fsck clean.
#
# DISCRIMINATION: pf_append_serial=1, one round trip per block: the same
# punches cost several times the requests.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in pf_force_foreign pf_append_serial hb_interval_secs; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
N=3000
ct_param_set hb_interval_secs 60 # read at mount: no drain during the punches
MNT="$(ct_mnt pfone)"
ct_track mnt "$MNT"

# <serial 0|1> -> "<appends> <reads> <free before> <free after remount> <fsck clean|ERR>"
round() {
    local dev info a0 r0 a1 r1 f0 f1 out
    dev="$(ct_loop "$(ct_image 1200 "pfone$1")")"
    ct_mkfs "$dev" -f >/dev/null
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    python3 - "$MNT/f" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(int(sys.argv[2])):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
    sync
    f0="$(stat -f -c %f "$MNT")"
    ct_param_set pf_force_foreign 1
    ct_param_set pf_append_serial "$1"
    a0="$(sed -n 's/^pending_free_appends: //p' "$info")"
    r0="$(sed -n 's/^pf_append_reads: //p' "$info")"
    python3 - "$MNT/f" "$N" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR)
for i in range(int(sys.argv[2])):
    if libc.fallocate(fd, 0x03, ctypes.c_long(2 * i * 4096), ctypes.c_long(4096)) != 0:  # PUNCH_HOLE|KEEP_SIZE
        raise OSError(ctypes.get_errno(), "punch")
os.close(fd)
PY
    a1="$(sed -n 's/^pending_free_appends: //p' "$info")"
    r1="$(sed -n 's/^pf_append_reads: //p' "$info")"
    ct_param_set pf_append_serial 0
    ct_param_set pf_force_foreign 0
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    rm -f "$MNT/f"
    sync
    f1="$(stat -f -c %f "$MNT")"
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^(ERR|WARN)' <<<"$out" && out=ERR || out=clean
    echo "$((a1 - a0)) $((r1 - r0)) $f0 $f1 $out"
}

read -r A R F0 F1 FS <<<"$(round 0)"
log "chunked: $A appends, $R planning reads; free $F0 before, $F1 after the remount; fsck $FS"
read -r A0 R0 G0 G1 FS0 <<<"$(round 1)"
log "per block: $A0 appends, $R0 planning reads"
# 16 entries per region, 8 regions per block: N entries fill N/128 blocks.
BLK=$((N / 128))
[ "$A" -ge "$N" ] && [ "$BLK" -gt 8 ] ||
    { fail "setup: $A appends for $N punches, queue grows to ~$BLK blocks -- the front never fills past a chunk"; ct_exit; }
pass "setup: $A appends, the queue grew to ~$BLK blocks"
[ "$R" -le $((A + A * BLK / 8)) ] &&
    pass "1: $A appends took $R planning reads (per block: $R0)" ||
    fail "1: $A appends took $R planning reads, more than one per chunk scanned (per block: $R0)"
[ "$R0" -ge $((R * 3)) ] && pass "control: one round trip per block costs $R0 reads, at least 3x" ||
    fail "control: per block took $R0 reads against $R -- the test does not discriminate"
[ "$FS" = clean ] && [ "$F1" -ge "$F0" ] && pass "2: after the remount the queue is applied: free $F1 >= $F0, fsck clean" ||
    fail "2: free $F1 vs $F0 before, fsck $FS"
ct_exit
