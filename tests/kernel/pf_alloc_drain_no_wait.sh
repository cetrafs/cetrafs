#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a drain run from a write's allocation does not back off on a busy queue region; the mount's and heartbeat's do
#
# A drain whose consume of a region keeps losing to appenders retries it,
# backing off 1, 2, 4 ... 128 ms -- about a quarter of a second -- before
# holding its entries for the next pass. That is right on the heartbeat.
# But the allocator also drains (rate limited), from inside a write,
# under that write's inode_lock and invalidate_lock: each busy region
# added a quarter second to a VM's write, and several compound
# (review F4). With the hold in place the retry buys promptness only,
# never correctness, so a drain from the allocation path tries a busy
# region once and holds it.
#
#  1. CONTROL: the mount's drain over a queue with a busy region DOES
#     back off -- so the region really is busy, and 2's absence of waits
#     is the allocator's choice, not an empty queue.
#  2. a write whose allocation drains the same queue: no back-off is
#     counted, and the write does not take the quarter second.
#  3. the held entry is still queued afterwards, for a later drain.
#
# DISCRIMINATION (2026-11-11, the allocator's drain given the back-off
# again): case 2 counts 8 back-offs and the write takes 311 ms, against
# 8 ms with the fix.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in pf_drain_busy_region pf_drain_min_ms hb_interval_secs; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"

IMG="$(ct_image 560 pfnowait)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfnowait)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set pf_drain_min_ms 600000 # no allocator drain until case 2 asks
ct_param_set hb_interval_secs 3600  # no heartbeat drain inside the measured write

info() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/info"; }
ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
queued() { "$PP" "$IMG" dump 0 | grep -c "^$FREEBLK 1\$" || true; }

# A block far past anything this suite allocates, and free: queuing its
# free changes nothing when it is applied.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/probe" bs=4096 count=1 conv=fsync status=none
FREEBLK=$(($(ext "$MNT/probe") + 3000))
rm -f "$MNT/probe"
W0="$(info pf_drain_busy_waits)"
ct_umount "$MNT"

"$PP" "$IMG" put 0 0 0 "$FREEBLK" 1 >/dev/null # queue block 0, region 0
ct_param_set pf_drain_busy_region 1

# ------------------------------------------------------------------- 1
log "1: CONTROL -- the mount's drain backs off on the busy region"
ct_mount "$DEV" "$MNT"
W1="$(info pf_drain_busy_waits)"
[ "$((W1 - W0))" -ge 1 ] && pass "1: the mount's drain waited on the busy region ($((W1 - W0)) back-off(s))" ||
    { fail "1: the mount's drain did not wait -- the region is not busy, and 2 would prove nothing"; ct_exit; }

# ------------------------------------------------------------------- 2
log "2: a write's allocation drains the same queue"
H0="$(info pf_drain_sweeps)"
ct_param_set pf_drain_min_ms 0
T0="$(date +%s%N)"
dd if=/dev/urandom of="$MNT/w" bs=4096 count=1 conv=fsync status=none
T1="$(date +%s%N)"
ct_param_set pf_drain_min_ms 600000
W2="$(info pf_drain_busy_waits)"
H1="$(info pf_drain_sweeps)"
MS=$(((T1 - T0) / 1000000))
[ "$H1" -gt "$H0" ] && pass "2 setup: the write's allocation ran a drain over the queue" ||
    { fail "2 setup: no drain swept the queue during the write -- nothing was measured"; ct_exit; }
[ "$W2" = "$W1" ] && pass "2: that drain did not back off" ||
    fail "2: the allocation path's drain backed off $((W2 - W1)) time(s), inside a write"
[ "$MS" -lt 200 ] && pass "2: and the write took ${MS} ms, not the quarter second the back-off costs" ||
    fail "2: the write took ${MS} ms"

# ------------------------------------------------------------------- 3
ct_param_set pf_drain_busy_region 0
ct_umount "$MNT"
[ "$(queued)" = 1 ] && pass "3: the held entry is still queued, for a later drain" ||
    fail "3: the busy region's entry is gone though no drain could consume it ($(queued) queued)"
# The region no longer busy, the next drain (this mount's) completes it.
# (A queued free of a block already free is a state fsck rejects: it is
# staged here only to be drained.)
ct_mount "$DEV" "$MNT"
ct_umount "$MNT"
[ "$(queued)" = 0 ] || fail "3: the entry was not consumed once its region came free"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
