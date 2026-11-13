#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# -o discard claims a freed run before its UNMAP: a writer allocating meanwhile is never given it
#
# The inline-discard worker runs a moment after the free, and by then the
# allocator may have handed the blocks to another file; an UNMAP landing
# on them destroys that file's data, silently. The worker therefore
# discards only what reads free when it gets there, and only while it is
# CLAIMED -- fstrim's claim, the same code (cetrafs_trim_claim_next()):
# bits set as an allocation sets them, so no writer can be given them
# until the discard is done.
#
# Two actors: the worker, held between its claim and its discard
# (inline_discard_stall_ms), and a writer allocating 4 MiB inside that
# window. The freed run is the 8 MiB a deleted file left at the front of
# the data, which is also where the allocator puts the next file if it
# can.
#
#  1. the claim: the writer is placed elsewhere, and after the UNMAP its
#     data reads back intact from the device; fsck clean.
#  2. NEGATIVE CONTROL, trim_skip_claim: the worker finds the run and
#     does not claim it. The writer is given the hole, and after the
#     UNMAP it no longer reads what was written.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in inline_discard_delay_ms inline_discard_stall_ms trim_skip_claim; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"

IMG="$(ct_big_image 1200 idclaim)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt idclaim)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set inline_discard_delay_ms 200

ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
sum() { md5sum <"$1" | awk '{ print $1 }'; }
in_hole() { [ "$1" -ge "$HOLE" ] && [ "$1" -lt $((HOLE + 2048)) ]; }

# round <tag> <skip_claim>: an 8 MiB file deleted with -o discard, the
# worker held 4 s on its claim, a 4 MiB writer inside the window. Sets
# W, WSUM, WLBA, HOLE, LOG.
round() {
    local mark i o="${CT_MOUNT_OPTS:-}"
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    CT_MOUNT_OPTS="${o:+$o,}discard" ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
    sync
    HOLE="$(ext "$MNT/h")"
    ct_param_set trim_skip_claim "$2"
    ct_param_set inline_discard_stall_ms 4000
    mark="$(dmesg_mark)"
    rm -f "$MNT/h"
    sync
    for i in $(seq 1 50); do
        dmesg_since "$mark" | grep -q "inline discard: claimed \[$HOLE " && break
        sleep 0.1
    done
    dmesg_since "$mark" | grep -q "inline discard: claimed \[$HOLE " ||
        { fail "$1 setup: the worker never reached the hole ($(dmesg_since "$mark" | grep -m1 'inline discard'))"; ct_exit; }
    # The second actor, inside the window.
    W="$MNT/w$1"
    dd if=/dev/urandom of="$W" bs=1M count=4 conv=fsync status=none
    WSUM="$(sum "$W")"
    WLBA="$(ext "$W")"
    ct_param_set inline_discard_stall_ms 0 # later claims need no window
    sleep 4.5                              # the held claim's discard runs at the end of its window
    ct_param_set trim_skip_claim 0
    LOG="$(dmesg_since "$mark")"
    # Re-read from the device, not the page cache.
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
}

log "1: a writer inside the claim's window"
round 1 0
! in_hole "$WLBA" && pass "1: the writer was placed outside the claimed run (at $WLBA; hole $HOLE)" ||
    fail "1: the writer was given block $WLBA, inside the run being discarded"
[ "$(sum "$W")" = "$WSUM" ] && pass "1: and reads back exactly what was written" ||
    fail "1: the writer's data changed across the discard"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "1: fsck clean" || fail "1: fsck: $(grep -m3 '^ERR' <<<"$OUT")"

log "2: NEGATIVE CONTROL -- no claim"
round 2 1
in_hole "$WLBA" || { fail "2 setup: the writer did not land in the hole ($WLBA; hole $HOLE) -- nothing to destroy"; ct_exit; }
pass "2 setup: unclaimed, the hole was given to the writer"
[ "$(sum "$W")" != "$WSUM" ] && pass "2: and the UNMAP destroyed its data -- which is what the claim prevents" ||
    fail "2: the writer's data survived an unclaimed discard: case 1 proves nothing"
ct_umount "$MNT"
ct_exit
