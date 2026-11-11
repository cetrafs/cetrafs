#!/usr/bin/env bash
# a FITRIM run is claimed before its UNMAP: no writer can be given it, and no free can let go of it
#
# A run read free can be handed to a file while its UNMAP is in flight,
# and the UNMAP then destroys that file's data -- silently, fsck sees
# nothing wrong. So each run is CLAIMED first (bits set, as an
# allocation sets them) and given back after (cetrafs_trim_claim_next()).
# Setting the bits is not the whole of it: a free path clears whatever
# set bit it finds, so a double free -- a peer's queued copy included --
# landing on a claimed block would undo the claim from underneath. The
# free paths treat a claimed block as already free (the HOLD).
#
# The claim's window is held open (trim_discard_stall_ms) and fstrim is
# limited to runs of 4 MiB or more, so the run claimed first is the 8 MiB
# hole a deleted file left at the front of the Block Group -- also where
# the allocator puts the next 4 MiB file, if it can.
#
#  1. the claim: a 4 MiB file written inside the window is placed
#     elsewhere and reads back intact after the UNMAP.
#  2. NEGATIVE CONTROL, trim_skip_claim: the same file lands in the
#     hole, and after the UNMAP it no longer reads what was written.
#     This is the control that proves the protocol, not the plumbing.
#  3. the hold: a queued free of a block inside the claimed run is
#     drained inside the window; the drain leaves it, the trim gives the
#     run back, and the mount and fsck are clean.
#  4. NEGATIVE CONTROL, trim_hold_off: the same drain clears the trim's
#     bit, and the give-back finds it gone and stops the mount.
#  5. the hold on the LOCAL free path: a file whose extent was pointed
#     (offline) at a block of the hole is deleted inside the window -- a
#     double free of a claimed block. Left alone, reported, mount
#     running; and with trim_hold_off the give-back stops the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
for p in trim_discard_stall_ms trim_skip_claim trim_hold_off pf_drain_min_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
# Cases 4 and 5's controls stop the mount, leaving a row that reads
# mounted: the next mkfs would watch it for the default 120 s.
export CETRAFS_PEER_PROBE_SECS=3
PP="$(ct_helper pending_poke)"
EPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_big_image 1200 ftclaim)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ftclaim)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set pf_drain_min_ms 600000 # drains only where a case asks for one

ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
sum() { md5sum <"$1" | awk '{ print $1 }'; }
shut() { grep -q "^shutdown: yes" "$(ct_procdir "$DEV")/controls"; }

# hole <tag>: a fresh volume with an 8 MiB hole at the front of its data,
# a kept file behind it. Sets HOLE (first block of the hole).
hole() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
    sync
    HOLE="$(ext "$MNT/h")"
    rm -f "$MNT/h"
    sync
}

# trim_bg: fstrim in the background, its first claim held 3 s.
trim_bg() {
    ct_param_set trim_discard_stall_ms 3000
    fstrim -m 4M "$MNT" >/dev/null 2>&1 &
    TPID=$!
    sleep 1 # well inside the first run's window
}
trim_done() {
    ct_param_set trim_discard_stall_ms 0 # the remaining runs need no window
    wait "$TPID" || true
}

in_hole() { [ "$1" -ge "$HOLE" ] && [ "$1" -lt $((HOLE + 2048)) ]; }

# writer <tag>: a 4 MiB file inside the window. Sets W, WSUM, WLBA.
writer() {
    W="$MNT/w$1"
    dd if=/dev/urandom of="$W" bs=1M count=4 conv=fsync status=none
    WSUM="$(sum "$W")"
    WLBA="$(ext "$W")"
}
reread() {
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
}

# ------------------------------------------------------------------- 1
log "1: a writer inside the claim's window"
hole 1
trim_bg
writer 1
trim_done
! in_hole "$WLBA" && pass "1: the writer was placed outside the claimed hole (at $WLBA; hole $HOLE)" ||
    fail "1: the writer was given block $WLBA, inside the run being trimmed"
reread
[ "$(sum "$W")" = "$WSUM" ] && pass "1: and reads back exactly what was written" ||
    fail "1: the writer's data changed across the trim"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "1: fsck clean" || fail "1: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"

# ------------------------------------------------------------------- 2
log "2: NEGATIVE CONTROL -- no claim"
hole 2
ct_param_set trim_skip_claim 1
trim_bg
writer 2
trim_done
ct_param_set trim_skip_claim 0
in_hole "$WLBA" || { fail "2 setup: the writer did not land in the hole ($WLBA; hole $HOLE) -- nothing to destroy"; ct_exit; }
pass "2 setup: unclaimed, the hole was given to the writer"
reread
[ "$(sum "$W")" != "$WSUM" ] && pass "2: and the UNMAP destroyed its data -- which is what the claim prevents" ||
    fail "2: the writer's data survived an unclaimed trim: case 1 proves nothing"
ct_umount "$MNT"

# ------------------------------------------------------------------- 3
# queue_free_in_window: a peer's free of one block of the claimed hole,
# queued and drained while the trim holds the run.
queue_free_in_window() {
    "$PP" "$IMG" put 0 0 0 $((HOLE + 5)) 1 >/dev/null
    ct_param_set pf_drain_min_ms 0
    dd if=/dev/urandom of="$MNT/trigger$1" bs=4096 count=1 conv=fsync status=none # a drain point
    ct_param_set pf_drain_min_ms 600000
    sleep 0.2
}

log "3: a queued free of a claimed block, drained inside the window"
hole 3
MARK="$(dmesg_mark)"
trim_bg
queue_free_in_window 3
trim_done
[ "$("$PP" "$IMG" dump 0 | grep -c "^$((HOLE + 5)) 1\$" || true)" = 0 ] &&
    pass "3 setup: the queued free was consumed inside the window" ||
    fail "3 setup: the queued free was still queued after the drain -- it never met the claim"
! shut && pass "3: the trim gave its run back and the mount is running" ||
    fail "3: the mount stopped: $(dmesg_since "$MARK" | grep -m1 -E 'trim|fatal')"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "3: fsck clean" || fail "3: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"

# ------------------------------------------------------------------- 4
log "4: NEGATIVE CONTROL -- no hold"
hole 4
MARK="$(dmesg_mark)"
ct_param_set trim_hold_off 1
trim_bg
queue_free_in_window 4
trim_done
ct_param_set trim_hold_off 0
dmesg_since "$MARK" | grep -q "of the claimed run .* were already clear" &&
    pass "4: without the hold the drain cleared the trim's bit, and the give-back caught it" ||
    fail "4: a free cleared a claimed bit and nothing noticed -- case 3 proves nothing"
shut && pass "4: and the mount stopped rather than give back a run it no longer held" ||
    fail "4: the mount kept running after its claim was undone"
ct_umount "$MNT" || true

# ------------------------------------------------------------------- 5
# local_double_free <tag> <hold_off>
local_double_free() {
    local ino mark
    hole "$1"
    dd if=/dev/urandom of="$MNT/d" bs=4096 count=1 conv=fsync status=none
    sync
    ino="$(stat -c %i "$MNT/d")"
    ct_umount "$MNT"
    "$EPOKE" "$IMG" "$ino" $((HOLE + 7)) >/dev/null
    ct_mount "$DEV" "$MNT"
    mark="$(dmesg_mark)"
    ct_param_set trim_hold_off "$2"
    trim_bg
    rm -f "$MNT/d"
    sync
    trim_done
    ct_param_set trim_hold_off 0
    LOG="$(dmesg_since "$mark")"
}

log "5: a local double free of a claimed block, inside the window"
local_double_free 5 0
grep -q "block $((HOLE + 7)) is being trimmed, so it was already free" <<<"$LOG" &&
    pass "5: the free left the claimed block alone, and said why" ||
    fail "5 setup: the free never met the claim ($(grep -m1 "$((HOLE + 7))" <<<"$LOG"))"
! shut && pass "5: the trim gave its run back and the mount is running" ||
    fail "5: the mount stopped: $(grep -m1 -E 'trim|fatal' <<<"$LOG")"
# No fsck verdict here: the poke left the file's real block allocated
# and unreferenced (a leak) by construction.
ct_umount "$MNT"

log "5: NEGATIVE CONTROL -- no hold on the local free"
local_double_free 5c 1
grep -q "of the claimed run .* were already clear" <<<"$LOG" && shut &&
    pass "5: without the hold the local free cleared the trim's bit, and the mount stopped" ||
    fail "5: a local free cleared a claimed bit and nothing noticed"
ct_umount "$MNT" || true
ct_exit
