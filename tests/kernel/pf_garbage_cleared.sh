#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a garbage pending-free entry alone in its region is cleared by the drain, and by fsck -r
#
# The drain clears a garbage entry (a slot with an address but a bad
# magic or a zero count) inside the swap that consumes its region's
# valid entries -- and skipped a region holding nothing else, so the
# garbage stayed, reported and counted as damage on every drain. fsck
# meanwhile did not see a bad-magic entry at all, and called a zero
# count fatal with nothing to repair it: kernel and fsck disagreed, and
# neither cleared it (audit 2026-11-15 BM-12).
#
# Staged: one entry with count 0 alone in ZG0's queue.
#   kernel: after the mount and a few drains the slot is empty and the
#           damage was counted once, not once per drain;
#   fsck:   reports the entry as garbage and -r clears it.
# DISCRIMINATION: pf_garbage_waits=1 skips a garbage-only region, as
# before -- the entry stays and the count keeps rising.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pf_garbage_waits ] || { skip "pf_garbage_waits is missing"; ct_exit; }
PP="$(ct_helper pending_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 560 pfgarb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfgarb)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set pf_garbage_waits 0
compress_timing
queued() { "$PP" "$DEV" dump 0 | grep -c . || true; }
stage() {
    ct_mkfs_small "$DEV" -z 1 >/dev/null
    "$PP" "$DEV" put 0 0 3 5000 0 >/dev/null
    blockdev --flushbufs "$DEV"
}
# <waits 0|1> -> RES
round() {
    stage
    echo "$1" >/sys/module/cetrafs/parameters/pf_garbage_waits
    ct_mount "$DEV" "$MNT"
    sleep 6 # the mount's drain and several one-second ticks
    RES="corrupt=$(sed -n 's/^corruptions: //p' "$(ct_procdir "$DEV")/info")"
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/pf_garbage_waits
    RES="$RES queued=$(queued)"
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

round 0
F="$RES"
round 1
C="$RES"
log "fixed: $F; control (garbage waits): $C"
[ "$(field queued "$C")" = 1 ] && [ "$(field corrupt "$C")" -ge 2 ] &&
    pass "control: skipped, the garbage stayed and was counted on every drain ($C)" ||
    fail "control: the garbage did not stay -- the suite does not stage it: $C"
[ "$(field queued "$F")" = 0 ] && [ "$(field corrupt "$F")" = 1 ] &&
    pass "the drain cleared the garbage and counted it once" || fail "fixed: $F"

stage
out="$("$FSCK" "$DEV" 2>&1)" && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -q "pending-free entry 3 is garbage" <<<"$out" &&
    pass "fsck reports the garbage entry" || fail "fsck: rc=$rc: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
[ "$(queued)" = 0 ] && "$FSCK" "$DEV" >/dev/null 2>&1 && pass "fsck -r cleared it, and the volume checks clean" ||
    fail "after fsck -r: queued=$(queued)"
ct_exit
