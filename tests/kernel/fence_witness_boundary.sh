#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a boundary asks the device whether this node was fenced, not only its clock
#
# The lease is judged on jiffies, and a node a hypervisor paused can
# resume with that clock where it stopped: a peer's verdict and its bump
# of this node's fence_epoch were then invisible to every gate until the
# next heartbeat tick -- up to a whole beat in which boundary flushes
# wrote bitmap blocks and discards went out over Zone Groups a peer had
# taken (audit 2026-11-15 B-18). A boundary with something to write now
# reads this node's own row fresh first, at most once a second, and
# fences on a moved epoch.
#
# The paused clock is played by a tick that does not look:
# fence_skip_precheck (the tick's own row check off) and hb_renew_fail
# (no renewal, so no CAS refusal either), with the default lease far
# longer than the suite. A peer's reclaim is the epoch bumped on the
# device. Then a writer allocates and fsyncs in a loop for 8 s.
#   setup: the writer's boundaries succeed before the bump;
#   1. after the bump, a boundary fails within 3 s and the mount is
#      fenced -- with the tick still blind.
#
# DISCRIMINATION: fence_witness_off=1 (the clock alone): every fsync of
# the 8 s succeeds and the mount is never fenced.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_witness_off ] || { skip "fence_witness_off is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt fwb)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0

# <old 0|1> -> "before=<n> after_ok=<n> first_err_ms=<ms|none> fenced=<yes|no>"
round() {
    local dev proc out
    dev="$(ct_dev 560 "fwb$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "$1" >/sys/module/cetrafs/parameters/fence_witness_off
    echo 1 >/sys/module/cetrafs/parameters/fence_skip_precheck
    echo 1 >/sys/module/cetrafs/parameters/hb_renew_fail
    out="$(python3 -I - "$MNT" "$NODE_POKE" "$dev" <<'PY'
import os, sys, time, subprocess
mnt, poke, dev = sys.argv[1:4]
blk = b"w" * 4096
def boundary(i):
    fd = os.open(os.path.join(mnt, "f%d" % i), os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        os.write(fd, blk)
        os.fsync(fd)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
before = 0
for i in range(5):
    try:
        boundary(i); before += 1
    except OSError:
        pass
    time.sleep(0.2)
subprocess.run([poke, dev, "0", "--bump-fence", "1"], check=True, stdout=subprocess.DEVNULL)
t0 = time.monotonic()
ok, first = 0, None
i = 100
while time.monotonic() - t0 < 8:
    try:
        boundary(i); ok += 1
    except OSError:
        if first is None:
            first = int((time.monotonic() - t0) * 1000)
            break
    i += 1
    time.sleep(0.1)
print("before=%d after_ok=%d first_err_ms=%s" % (before, ok, first if first is not None else "none"))
PY
)" || true
    local f
    f="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    echo 0 >/sys/module/cetrafs/parameters/hb_renew_fail
    echo 0 >/sys/module/cetrafs/parameters/fence_skip_precheck
    echo 0 >/sys/module/cetrafs/parameters/fence_witness_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    echo "$out fenced=$f"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (the clock alone): $C"
[ "$(get before "$R")" = 5 ] && [ "$(get before "$C")" = 5 ] || { fail "setup: boundaries failed before the bump ($R | $C)"; ct_exit; }
pass "setup: every boundary succeeded before the bump"
E="$(get first_err_ms "$R")"
[ "$E" != none ] && [ "$E" -lt 3000 ] && [ "$(get fenced "$R")" = yes ] &&
    pass "1: a boundary failed ${E} ms after the bump and the mount fenced, the tick still blind" ||
    fail "1: after the bump: first error at ${E} ms, fenced=$(get fenced "$R")"
[ "$(get first_err_ms "$C")" = none ] && [ "$(get fenced "$C")" = no ] &&
    pass "control: with the clock alone, $(get after_ok "$C") boundaries in 8 s went out after the bump" ||
    fail "control: the clock alone stopped the writer ($C) -- the suite does not isolate the witness"
ct_exit
