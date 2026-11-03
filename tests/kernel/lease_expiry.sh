#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node whose heartbeat cannot renew stops writing before peers may reclaim
#
# A peer calls a node dead after watching its heartbeat sit still for at
# least four of its intervals, then fences it and reclaims its locks and
# Zone Groups. The fenced node only found out from its own heartbeat
# tick -- which, behind a hung device, never completes -- while its other
# threads kept writing the moment I/O came back, into blocks the peers
# had taken over.
#
# The in-core lease: three intervals from the start of the last renewal
# that reached the device, checked on every write with no I/O, latched
# once it lapses.
#
#   A. renewals fail: writes stop with EIO within the lease, and the
#      mount reports itself fenced;
#   B. renewals come back: the node stays fenced (a peer may already
#      have reclaimed from it);
#   C. control: with the lease off (lease_force=0 on this no-CAW loop
#      device) the same failed renewals let writes go on.
#
# DISCRIMINATION: C is the old behaviour, measured in the same run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in lease_force hb_renew_fail; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 560 lease)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lease)"
ct_track mnt "$MNT"
INTERVAL=2

# <seconds>: write+fsync every 0.2 s; print the elapsed seconds of the
# first failure, or "none".
writer() {
    python3 -I - "$MNT/w" "$1" <<'PY'
import os, sys, time
t0 = time.monotonic()
fd = None
while time.monotonic() - t0 < float(sys.argv[2]):
    try:
        if fd is None:
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
        os.write(fd, b"x" * 4096)
        os.fsync(fd)
    except OSError as e:
        print("%.1f %s" % (time.monotonic() - t0, e.strerror), flush=True)
        sys.exit(0)
    time.sleep(0.2)
print("none", flush=True)
PY
}
fenced() { sed -n 's/^fenced: //p' "$(ct_procdir "$DEV")/info"; }

run() { # <lease_force>
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set hb_interval_secs "$INTERVAL"
    ct_param_set lease_force "$1"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    # Past the first renewal, which is what arms the lease.
    sleep $((INTERVAL * 2))
    R="$(writer 1)"
    [ "$R" = none ] || { fail "setup: writes failed before anything was broken: $R"; ct_exit; }
    ct_param_set hb_renew_fail 1
}
finish() {
    ct_param_set hb_renew_fail 0
    ct_param_set lease_force 0
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    ct_param_set hb_interval_secs 15
}

log "A/B: the lease armed, renewals failing"
MARK="$(dmesg_mark)"
run 1
R="$(writer $((INTERVAL * 8)))"
log "first failed write: $R"
if [ "$R" = none ]; then
    fail "A: writes went on for $((INTERVAL * 8)) s with no renewal reaching the device"
else
    T="${R%% *}"
    # Three intervals from the last good renewal, plus one tick of slack
    # for where in its interval the failures started.
    awk -v t="$T" -v lim="$((INTERVAL * 4 + 1))" 'BEGIN{exit !(t <= lim)}' &&
        pass "A: writes stopped ${T}s after renewals began failing (lease $((INTERVAL * 3)) s)" ||
        fail "A: writes stopped only after ${T}s -- later than the lease allows"
    grep -q "Input/output error" <<<"$R" && pass "A: the failure is EIO" || fail "A: the failure was not EIO: $R"
fi
[ "$(fenced)" = yes ] && pass "A: the mount reports itself fenced" || fail "A: procfs says fenced: $(fenced)"
grep -q "lease expired" <<<"$(dmesg_since "$MARK")" && pass "A: the kernel says why" ||
    fail "A: no 'lease expired' in dmesg"

ct_param_set hb_renew_fail 0
sleep $((INTERVAL * 2))
R="$(writer 1)"
[ "$R" != none ] && [ "$(fenced)" = yes ] &&
    pass "B: renewals work again, and the node stays fenced" ||
    fail "B: a lapsed lease came back to life ($R, fenced: $(fenced))"
finish

log "C: control -- the lease off, renewals failing"
run 0
R="$(writer $((INTERVAL * 8)))"
[ "$R" = none ] &&
    pass "C: without the lease the writes go on (the test discriminates)" ||
    fail "C: writes failed without the lease ($R) -- A proves nothing about it"
finish
ct_exit
