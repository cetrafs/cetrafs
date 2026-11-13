#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# -o discard: a discard of unknown outcome keeps its run allocated; a refused one frees it
#
# A discard that failed on the transport or timed out may still execute
# on the array, and an UNMAP landing after the blocks were handed out
# destroys the new owner's data (class 30). fstrim keeps such a run
# allocated, its bits synced, for the scrub; the inline-discard worker
# runs the same release, so it must keep it too -- and end its pass,
# since the path is failing. A discard the target REFUSED did not run,
# and its blocks are freed as usual.
#
#  A. unknown (discard_fail_unknown): an 8 MiB hole punched with
#     -o discard. The whole claimed run is kept (trim_leaked_blocks), the
#     next writer is placed outside it, and fsck finds every block of it
#     allocated and unreferenced -- a leak, never a share.
#  B. CONTRAST, refused (discard_fail_definite): nothing kept, the next
#     writer IS placed in the run, fsck finds none of it leaked. Proves
#     A's writer was kept out by the verdict, not by placement.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in inline_discard_delay_ms discard_fail_unknown discard_fail_definite; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"

IMG="$(ct_big_image 1200 idunk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt idunk)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set inline_discard_delay_ms 200

ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/info"; }
in_hole() { [ "$1" -ge "$HOLE" ] && [ "$1" -lt $((HOLE + 2048)) ]; }
leaked_in_hole() {
    CETRAFS_FSCK_DUMP_LEAKS=1 ct_fsck "$DEV" 2>&1 |
        awk -v lo="$HOLE" -v hi=$((HOLE + 2048)) -F'lba=' '/^LEAK: lba=/ { if ($2 >= lo && $2 < hi) n++ } END { print n + 0 }'
}

# round <fail param>: an 8 MiB file deleted with -o discard and one
# discard failing as <fail param> says. Sets HOLE, KEPT, ERRS, WLBA.
round() {
    local o="${CT_MOUNT_OPTS:-}" l0 e0 i
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    CT_MOUNT_OPTS="${o:+$o,}discard" ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
    sync
    HOLE="$(ext "$MNT/h")"
    l0="$(info trim_leaked_blocks)"; e0="$(info discard_errors)"
    ct_param_set "$1" 1
    rm -f "$MNT/h"
    sync
    for i in $(seq 1 30); do
        [ "$(info discard_errors)" -gt "$e0" ] && break
        sleep 0.2
    done
    sleep 0.5
    ct_param_set "$1" 0
    ERRS=$(($(info discard_errors) - e0))
    KEPT=$(($(info trim_leaked_blocks) - l0))
    [ "$ERRS" = 1 ] || { fail "$1 setup: $ERRS discard error(s), not the one injected"; ct_exit; }
    dd if=/dev/urandom of="$MNT/w" bs=1M count=4 conv=fsync status=none
    WLBA="$(ext "$MNT/w")"
    ct_umount "$MNT"
}

log "A: a discard of unknown outcome"
round discard_fail_unknown
[ "$KEPT" = 2048 ] && pass "A: the whole claimed run (2048 blocks) was kept" ||
    fail "A: kept $KEPT blocks, not the run's 2048"
! in_hole "$WLBA" && pass "A: the next writer was placed outside the kept run" ||
    fail "A: the next writer was given block $WLBA, inside a run whose UNMAP may still land"
N="$(leaked_in_hole)"
[ "$N" = 2048 ] && pass "A: fsck finds all 2048 blocks allocated and unreferenced -- a leak for the scrub" ||
    fail "A: fsck finds $N of the run's 2048 blocks leaked"

log "B: CONTRAST -- a discard the target refused"
round discard_fail_definite
[ "$KEPT" = 0 ] && pass "B: a refused discard keeps nothing" || fail "B: a refused discard kept $KEPT blocks"
in_hole "$WLBA" && pass "B: and the next writer IS placed in the run -- A's writer was kept out by the verdict" ||
    fail "B setup: the next writer was not placed in the hole even when it was free: A proves nothing"
N="$(leaked_in_hole)"
[ "$N" = 0 ] && pass "B: fsck finds none of the run leaked" || fail "B: fsck finds $N blocks of the run leaked"
ct_exit
