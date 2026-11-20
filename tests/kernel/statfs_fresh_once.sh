#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# statfs reads the Zone Group table fresh at most once a window, whoever asks
#
# statfs forced a fresh read of the whole Zone Group table on every call,
# for any user, as often as asked: a `df` loop in a container was read
# load on the LUN every node shares (audit M-32, BM-51). The fresh read
# is now made at most once per statfs_fresh_ms (a second); in between,
# each record comes from the buffer cache that read filled.
#   1. an unprivileged statfs loop costs a handful of fresh reads, not
#      one per call;
#   2. inside the window, this node's own allocation still moves df at
#      once, and the cached figure equals the fresh one: this node's own
#      records are current in its cache (its CAS installs what it wrote);
#   3. inside the window, a peer's change to another group is NOT seen
#      (so the cache is what answered) -- and once the window is over, it
#      is;
#   4. fsck clean once the poke is undone.
# A "peer" is zg_poke writing the record into the backing file: it
# reaches the device and not this node's buffer cache, as a peer's write
# does.
#
# DISCRIMINATION: statfs_fresh_ms=0 reads fresh on every call, as before:
# the same loop must cost at least one read request per call.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
[ -w "$P/statfs_fresh_ms" ] || { skip "statfs_fresh_ms is missing"; ct_exit; }
command -v setpriv >/dev/null || { skip "setpriv is missing"; ct_exit; }
ZG_POKE="$(ct_helper zg_poke)"
IMG="$(ct_image 16384 sfo)" # sparse: 16 Block Groups of 1 GiB
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt sfo)"
ct_track mnt "$MNT"
ct_param_set statfs_fresh_ms "$(cat $P/statfs_fresh_ms)"
ct_param_set zg_prefetch_off 0
ct_mkfs "$DEV" -z 16 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
chmod 0755 "$MNT"
dd if=/dev/zero of="$MNT/seed" bs=1M count=8 conv=fsync status=none

reads() { awk '{print $1}' "/sys/block/$(basename "$DEV")/stat"; }
bfree() { stat -f -c %f "$MNT"; }
# <secs>: an unprivileged statfs loop; prints "<calls> <read requests>"
loop() {
    local r0 calls
    r0="$(reads)"
    calls="$(setpriv --reuid=65534 --regid=65534 --clear-groups python3 -c '
import os, sys, time
end, n = time.monotonic() + float(sys.argv[2]), 0
while time.monotonic() < end:
    os.statvfs(sys.argv[1]); n += 1
print(n, flush=True)' "$MNT" "$1")"
    echo "$calls $(($(reads) - r0))"
}

# 1. the shipped window, against none
echo 1000 >"$P/statfs_fresh_ms"
read -r C R <<<"$(loop 3)"
echo 0 >"$P/statfs_fresh_ms"
read -r C0 R0 <<<"$(loop 1)"
log "unprivileged statfs: window 1 s: $C calls, $R read requests; no window: $C0 calls, $R0 requests"
[ "$C" -ge 300 ] && [ "$C0" -ge 50 ] || { fail "setup: the loop made too few calls ($C, $C0)"; ct_exit; }
[ "$R0" -ge "$C0" ] && pass "control: with no window every call reads the table fresh ($R0 requests, $C0 calls)" ||
    fail "control: $R0 requests for $C0 calls with no window -- the loop does not reach the device"
# Per fresh read: R0/C0 requests. Three seconds is at most four reads,
# plus the odd other read of an idle mount.
PER=$(((R0 + C0 - 1) / C0))
[ "$R" -le $((PER * 4 + 8)) ] && pass "1: $C calls in 3 s cost $R read requests (one fresh table read is $PER)" ||
    fail "1: $C calls in 3 s cost $R read requests -- more than four fresh reads of $PER"

# 2. a long window: one fresh read, then this node's own allocation
echo 0 >"$P/statfs_fresh_ms"
bfree >/dev/null # with no window: the next call fills
echo 600000 >"$P/statfs_fresh_ms"
F0="$(bfree)"    # the fill; a ten-minute window starts
dd if=/dev/zero of="$MNT/f" bs=1M count=8 conv=fsync status=none
F1="$(bfree)"                                     # inside the window
echo 0 >"$P/statfs_fresh_ms"
FF="$(bfree)"                                     # fresh
log "own write inside the window: before $F0, cached $F1, fresh $FF"
[ "$F1" -le $((F0 - 2048)) ] && pass "2a: inside the window, this node's own 8 MiB moves df at once ($F0 -> $F1)" ||
    fail "2a: inside the window df did not see this node's own write ($F0 -> $F1)"
[ "$F1" = "$FF" ] && pass "2b: the cached figure equals the fresh one ($F1)" ||
    fail "2b: cached $F1, fresh $FF -- this node's own record is stale in its cache"

# 3. a peer's change to a group this node does not own
ZG=""
for z in $(seq 0 15); do
    # 65535: CETRAFS_NODE_ID_NONE, a group nobody owns
    [ "$("$ZG_POKE" "$IMG" "$z" | sed -n 's/^owner_node_id=\([0-9]*\).*/\1/p')" = 65535 ] && { ZG="$z"; break; }
done
[ -n "$ZG" ] || { fail "setup: no unowned Zone Group to change"; ct_exit; }
ORIG="$("$ZG_POKE" "$IMG" "$ZG" | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
[ "$ORIG" -ge 1000 ] || { fail "setup: ZG$ZG has $ORIG free blocks"; ct_exit; }
echo 600000 >"$P/statfs_fresh_ms"
G0="$(bfree)" # fresh (the window was 0): fills and starts it
"$ZG_POKE" "$IMG" "$ZG" free $((ORIG - 1000)) >/dev/null
G1="$(bfree)" # inside the window
echo 0 >"$P/statfs_fresh_ms"
G2="$(bfree)" # the window over
"$ZG_POKE" "$IMG" "$ZG" free "$ORIG" >/dev/null
log "peer's change to ZG$ZG: before $G0, inside the window $G1, after it $G2"
[ "$G1" = "$G0" ] && pass "3a: inside the window the cache answers: the peer's change is not read ($G1)" ||
    fail "3a: inside the window statfs read the device ($G0 -> $G1)"
[ "$G2" = $((G0 - 1000)) ] && pass "3b: once the window is over the peer's change is seen ($G0 -> $G2)" ||
    fail "3b: after the window statfs reports $G2, expected $((G0 - 1000))"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "4: fsck clean" || fail "4: fsck"
ct_exit
