#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the lease runs as long as the stale window the node advertises, less one beat
#
# The in-core lease was three heartbeat intervals whatever the stale
# window: 45 s by default, against the 120 s every peer waits before it
# may call the node dead. A controller failover or a queued multipath
# stall of 60 s therefore stopped every node of the cluster at once --
# each self-fenced, every I/O EIO until remount -- although no peer
# could have reclaimed anything (audit 2026-11-14 O1).
#
# The lease is now the soonest window any peer may use on this node --
# the larger of four beats and the stale window its row advertises, when
# that is a legal one -- less one beat (cetrafs_sb_lease_secs()); the
# observer floors its window at the same value
# (cetrafs_peer_window_floor_secs()).
#
# With a 2 s beat and a 20 s window the lease is 18 s:
#   A. renewals fail for 10 s, then come back: writes never stop and the
#      mount is not fenced;
#   B. renewals fail for good: writes still stop with EIO, within the
#      lease plus a beat.
#
# DISCRIMINATION: lease_three_beats sizes the lease as before (6 s); A
# must then stop the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in lease_three_beats hb_renew_fail; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 560 leasew)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt leasew)"
ct_track mnt "$MNT"
INTERVAL=2
STALE=20

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

start() { # <lease_three_beats 0|1>
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set hb_interval_secs "$INTERVAL"
    ct_param_set stale_secs "$STALE"
    ct_param_set lease_three_beats "$1"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    sleep $((INTERVAL * 2)) # past the first renewal, which arms the lease
    R="$(writer 1)"
    [ "$R" = none ] || { fail "setup: writes failed before anything was broken: $R"; ct_exit; }
}
finish() {
    ct_param_set hb_renew_fail 0
    ct_param_set lease_three_beats 0
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
}
# A 10 s renewal outage, then renewals back: "<first failure|none> <fenced>"
outage() {
    ct_param_set hb_renew_fail 1
    local r
    r="$(writer 10)"
    ct_param_set hb_renew_fail 0
    sleep $((INTERVAL * 2))
    [ "$r" = none ] && r="$(writer 1)"
    echo "${r%% *} $(fenced)"
}

log "A: a 10 s outage inside an 18 s lease"
start 0
read -r R F <<<"$(outage)"
[ "$R" = none ] && [ "$F" = no ] && pass "A: writes went on through a 10 s renewal outage, not fenced" ||
    fail "A: a 10 s outage stopped the mount (first failure ${R}s, fenced: $F) -- the lease is shorter than the window"

log "B: renewals fail for good"
ct_param_set hb_renew_fail 1
R="$(writer $((STALE + 6)))"
if [ "$R" = none ]; then
    fail "B: writes went on for $((STALE + 6)) s with no renewal reaching the device"
else
    T="${R%% *}"
    # 10 s of A's outage already spent nothing: the renewals between A
    # and B re-armed the lease, which is 18 s from the last good one.
    awk -v t="$T" -v lim="$((STALE - INTERVAL + INTERVAL + 1))" 'BEGIN{exit !(t <= lim)}' &&
        pass "B: writes stopped ${T}s after renewals began failing (lease $((STALE - INTERVAL)) s)" ||
        fail "B: writes stopped only after ${T}s -- later than the lease allows"
fi
finish

log "control: the lease at three beats"
start 1
read -r R F <<<"$(outage)"
[ "$R" != none ] && [ "$F" = yes ] && pass "control: three beats stop the mount in the same outage (${R}s) -- the suite discriminates" ||
    fail "control: the three-beat lease rode out the outage too ($R, fenced $F) -- the suite cannot tell"
finish
ct_exit
