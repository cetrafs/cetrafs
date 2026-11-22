#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a trimmed run whose discard outcome is unknown is kept from the scrub for its quarantine
# ct-timeout: 240
#
# FITRIM claims a free run, discards it and gives it back. A discard that
# fails on a timeout or an I/O error may still execute -- a command can
# outlive the path that failed it over -- so the run is left allocated
# (discard_unknown_outcome.sh, A). Allocated was all it was: nothing
# names those blocks, so the scrub reclaimed them as leaked two passes
# and scrub_gap_secs apart, and the allocator then handed them to a file
# while the UNMAP could still be queued (audit 2026-11-22 N-24). The run
# is now also held on the reservation registry for trim_quarantine_secs,
# and only then left to the scrub.
#
# With the scrub on a 2 s cycle and a 30 s quarantine:
#   setup: fstrim over a failing discard keeps the whole run (2048
#          blocks) and info says one run is quarantined;
#   1. three scrub cycles later the scrub has reclaimed nothing of it;
#   2. once the quarantine is over the scrub does reclaim it -- the hold
#      ends, it is not a permanent leak -- and fsck finds no leak.
#
# DISCRIMINATION (measured with the hold removed): check 1 fails, the
# scrub reclaiming the run in its first cycles.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
for p in discard_fail_unknown trim_quarantine_secs scrub_gap_floor_secs; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
IMG="$(ct_big_image 1200 tuq)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt tuq)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set auto_defrag 0
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set trim_quarantine_secs 30
ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }

ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
sync
rm -f "$MNT/h"
sync

L0="$(info trim_leaked_blocks)"
ct_param_set discard_fail_unknown 1
fstrim -m 4M "$MNT" >/dev/null 2>&1 || true
ct_param_set discard_fail_unknown 0
T0=$(date +%s)
KEPT=$(($(info trim_leaked_blocks) - L0))
[ "$KEPT" = 2048 ] && [ "$(info trim_quarantined)" = 1 ] &&
    pass "setup: the failing discard's run (2048 blocks) was kept and is quarantined" ||
    { fail "setup: kept $KEPT blocks, $(info trim_quarantined) run(s) quarantined"; ct_exit; }

R0="$(info scrub_reclaimed)" C0="$(info scrub_cycles)"
for _ in $(seq 1 60); do [ "$(info scrub_cycles)" -ge $((C0 + 3)) ] && break; sleep 0.5; done
C1="$(info scrub_cycles)" R1="$(info scrub_reclaimed)"
if [ "$C1" -lt $((C0 + 3)) ]; then
    fail "1: setup: the scrub ran $((C1 - C0)) cycle(s), not 3 -- nothing was asked of it"
elif [ $(($(date +%s) - T0)) -ge 30 ]; then
    fail "1: setup: the three cycles took past the 30 s quarantine -- the check cannot tell"
elif [ "$R1" = "$R0" ] && [ "$(info trim_quarantined)" = 1 ]; then
    pass "1: three scrub cycles reclaimed nothing of the quarantined run"
else
    fail "1: the scrub reclaimed $((R1 - R0)) block(s) during the quarantine"
fi

for _ in $(seq 1 120); do
    [ "$(info trim_quarantined)" = 0 ] && [ "$(info scrub_reclaimed)" -ge $((R0 + 2048)) ] && break
    sleep 0.5
done
[ "$(info trim_quarantined)" = 0 ] && [ "$(info scrub_reclaimed)" -ge $((R0 + 2048)) ] &&
    pass "2: after the quarantine the scrub reclaimed the run ($(($(info scrub_reclaimed) - R0)) blocks)" ||
    fail "2: after the quarantine: $(info trim_quarantined) run(s) held, $(($(info scrub_reclaimed) - R0)) reclaimed"
ct_umount "$MNT"
N="$(CETRAFS_FSCK_DUMP_LEAKS=1 ct_fsck "$DEV" 2>&1 | grep -c '^LEAK: lba=' || true)"
[ "$N" = 0 ] && pass "2: fsck finds no leaked block" || fail "2: fsck finds $N leaked block(s)"
ct_exit
