#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an emptied Block Group is UNMAPped as it goes back to the pool: the space really returns
#
# The heartbeat hands an empty Block Group back to the unowned pool
# within a tick of the delete that emptied it, so most freed space
# leaves this node before anyone runs fstrim -- and a trim limited to
# owned Block Groups would never reach it. The release therefore
# discards the group's data region on the way out (discard.c), and the
# pool only ever holds space already given back to the array.
#
# The oracle is the loop device's backing file: a loop device implements
# discard by punching holes in it, so `du` on the image is "did the
# space come back", directly. Without that assertion the feature could
# be a no-op and every other check still pass.
#
#  1. on: delete what filled a Block Group; they are handed back, a
#     hand-back discard is counted, and the image shrinks by about that.
#  2. NEGATIVE CONTROL -- discard=off: the same delete, the same
#     hand-back, and the image does NOT shrink. Proves the drop in 1 is
#     the discard and not something else freeing the image's pages.
#  3. a device without discard: the hand-back still happens (discard is
#     best effort, releasing is not), fstrim says "not supported", and
#     the controls file says the device has none.
#  The mount reports which it is, once, in dmesg (1 and 3).
#  4. a FITRIM claim inside an emptied group while the heartbeat tries
#     to release it: the release's pre-check sees the claim's debit (an
#     accrued delta, not yet on the descriptor) and leaves the group
#     alone, so the claim gives its run back instead of leaking it as
#     "the BG left this node" (review U4). The group is handed back
#     once the trim is done.
#     DISCRIMINATION (2026-11-11, the pre-check reading the raw
#     descriptor count again): the run is leaked.
# fsck clean after each.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

BGPOKE="$(ct_helper bg_poke)"
IMG="$(ct_big_image 1200 dhb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dhb)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] || { skip "this loop device takes no discards (backing fs?)"; ct_exit; }

# Two 512 MiB Block Groups. Group 0 holds the root directory and can
# never go empty, so it is filled with a preallocated file -- blocks
# allocated, nothing written, the image stays small -- and the data
# under test lands in group 1, which can.
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
BG0_FREE="$("$BGPOKE" "$IMG" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
[ -n "$BG0_FREE" ] && [ "$BG0_FREE" -gt 1024 ] || { fail "setup: cannot read Block Group 0's free count"; ct_exit; }
compress_timing
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
dmesg_since "$MARK" | grep -q "$(basename "$DEV"): UNMAP supported: up to [0-9]* KiB per command, granularity [0-9]* KiB; hand-back discard on" &&
    pass "1: the mount says the device takes UNMAP" || fail "1: the mount did not report the device's UNMAP support"
fallocate -l $(((BG0_FREE - 256) * 4096)) "$MNT/pad"
sync

used_kb() { du -k "$IMG" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

# fill_and_delete: 96 MiB in a subdirectory removed whole (a directory
# never gives back its dirent blocks on unlink -- see
# bg_release_empty.sh), so whole Block Groups go empty. Sets BEFORE (the
# image with the data on it) and waits for a hand-back after the delete.
fill_and_delete() {
    local mark i
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    BEFORE="$(used_kb)"
    mark="$(dmesg_mark)"
    rm -rf "$MNT/bulk"
    sync
    for i in $(seq 1 40); do
        dmesg_since "$mark" | grep -q "handed back from ZG" && break
        sleep 0.5
    done
    sleep 2 # the rest of the pass
    HANDED="$(dmesg_since "$mark" | grep -c "handed back from ZG" || true)"
}

# ------------------------------------------------------------------- 1
log "1: discard on (the default)"
grep -q "^discard: on" "$PROC/controls" && pass "1: discard is on by default" || fail "1: discard is not on by default"
grep -q "^discard_supported: yes" "$PROC/controls" && pass "1: the loop device is reported as taking discards" ||
    fail "1: controls says this loop device takes no discards"
EMPTY="$(used_kb)"
HB0="$(info discard_handback_bgs)"
fill_and_delete
[ $((BEFORE - EMPTY)) -ge 90000 ] && pass "1 setup: the data occupies $(((BEFORE - EMPTY) / 1024)) MiB of the image" ||
    { fail "1 setup: writing 96 MiB grew the image by only $(((BEFORE - EMPTY) / 1024)) MiB"; ct_exit; }
[ "$HANDED" -ge 1 ] && pass "1 setup: $HANDED emptied Block Group(s) handed back" ||
    { fail "1 setup: only $HANDED Block Group(s) handed back after the delete"; ct_exit; }
AFTER="$(used_kb)"
HB1="$(info discard_handback_bgs)"
[ "$HB1" -gt "$HB0" ] && pass "1: $((HB1 - HB0)) hand-back discard(s) issued" || fail "1: no hand-back discard was counted"
[ $((BEFORE - AFTER)) -ge 60000 ] && pass "1: the image gave back $(((BEFORE - AFTER) / 1024)) MiB after the delete" ||
    fail "1: the image gave back only $(((BEFORE - AFTER) / 1024)) MiB of the ~96 MiB the delete freed"

# ------------------------------------------------------------------- 2
log "2: NEGATIVE CONTROL -- discard off"
echo "discard=off" >"$PROC/controls"
grep -q "^discard: off" "$PROC/controls" || fail "2 setup: the control did not turn discard off"
grep -q "nodiscard" <<<"$(grep " $MNT " /proc/mounts)" && pass "2: /proc/mounts shows nodiscard" ||
    fail "2: /proc/mounts does not show the switch is off"
HB0="$(info discard_handback_bgs)"
fill_and_delete
[ "$HANDED" -ge 1 ] || { fail "2 setup: only $HANDED Block Group(s) handed back -- the control compares nothing"; ct_exit; }
AFTER="$(used_kb)"
[ "$(info discard_handback_bgs)" = "$HB0" ] && pass "2: no hand-back discard with discard off" ||
    fail "2: a hand-back discard was issued with discard off"
[ $((BEFORE - AFTER)) -lt 16000 ] && pass "2: and the image kept the space ($(((BEFORE - AFTER) / 1024)) MiB back) -- so 1's drop is the discard" ||
    fail "2: the image shrank by $(((BEFORE - AFTER) / 1024)) MiB with discard off: 1 measured something else"
echo "discard=on" >"$PROC/controls"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "1-2: fsck clean" || fail "1-2: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"

# ------------------------------------------------------------------- 4
log "4: a FITRIM claim in an emptied group, racing its release"
if command -v fstrim >/dev/null && [ -w /sys/module/cetrafs/parameters/trim_discard_stall_ms ]; then
    ct_mount "$DEV" "$MNT"
    ct_param_set bg_release_off 1 # the group goes empty and stays ours
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    rm -rf "$MNT/bulk"
    sync
    L0="$(info trim_leaked_blocks)"
    MARK="$(dmesg_mark)"
    ct_param_set trim_discard_stall_ms 3000
    fstrim -m 4M "$MNT" >/dev/null 2>&1 & # group 0 has no 4 MiB run: the claim is in the emptied one
    TPID=$!
    sleep 1
    # A release that drains the group holds it drained across the claim's
    # give-back -- the window is otherwise a few milliseconds wide.
    ct_param_set bg_release_drain_stall_ms 4000
    ct_param_set bg_release_off 0 # the next ticks try to release it, under the claim
    sleep 3
    ct_param_set trim_discard_stall_ms 0
    wait "$TPID" || true
    [ "$(info trim_leaked_blocks)" = "$L0" ] && pass "4: the claim gave its run back -- the release left the group alone" ||
        fail "4: $(($(info trim_leaked_blocks) - L0)) block(s) leaked: the release drained the group under the claim"
    wait_for 20 "dmesg_since '$MARK' | grep -q 'handed back from ZG'" &&
        pass "4: and the group was handed back once the trim was done" ||
        fail "4 setup: the emptied group was never handed back -- the release never ran"
    ct_umount "$MNT"

    # --------------------------------------------------------------- 5
    # 4's release sees the claim's debit and never drains. A release
    # whose emptiness check ran just BEFORE the claim gets past it and
    # drains under the claim; skipping the check stands in for that. The
    # drain itself must refuse, or the give-back finds the group "gone"
    # and leaks its run in a group that never left.
    log "5: a release past its emptiness check, draining under a FITRIM claim"
    ct_mount "$DEV" "$MNT"
    ct_param_set bg_release_off 1
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    rm -rf "$MNT/bulk"
    sync
    L0="$(info trim_leaked_blocks)"
    MARK="$(dmesg_mark)"
    ct_param_set trim_discard_stall_ms 9000
    fstrim -m 4M "$MNT" >/dev/null 2>&1 &
    TPID=$!
    sleep 1
    # Past the check, group 0 (it holds the root) is a candidate too and
    # drains first: its pause is the one-shot stall. Re-armed while it
    # pauses, the stall then holds the CLAIMED group drained across the
    # give-back at ~9 s.
    ct_param_set bg_release_skip_empty_check 1
    ct_param_set bg_release_drain_stall_ms 4000
    ct_param_set bg_release_off 0
    wait_for 10 "dmesg_since '$MARK' | grep -q 'BG 0 release: drained, pausing'" ||
        fail "5 setup: no release drained group 0 -- the stall is not where the claim is"
    ct_param_set bg_release_drain_stall_ms 6000
    wait "$TPID" || true
    ct_param_set trim_discard_stall_ms 0
    ct_param_set bg_release_skip_empty_check 0
    [ "$(info trim_leaked_blocks)" = "$L0" ] && pass "5: the claim gave its run back -- the drain refused the claimed group" ||
        fail "5: $(($(info trim_leaked_blocks) - L0)) block(s) leaked: the release drained the group under the claim"
    wait_for 20 "dmesg_since '$MARK' | grep -q 'handed back from ZG'" &&
        pass "5: and the group was handed back once the trim was done" ||
        fail "5 setup: the emptied group was never handed back -- the release never ran"
    ct_umount "$MNT"
fi

# ------------------------------------------------------------------- 3
log "3: a device that takes no discards"
# A dm-linear device over the same loop, with its discard limit turned
# off. Not the loop device itself: a loop device's limit written to 0
# survives detach and cannot be raised again, so every later suite
# handed that loop number would silently lose discard.
command -v dmsetup >/dev/null || { skip "3: no dmsetup"; ct_exit; }
DMN="ctdhb$$"
dmsetup create "$DMN" --table "0 $(blockdev --getsz "$DEV") linear $DEV 0" || { fail "3 setup: dmsetup"; ct_exit; }
ct_track dm "$DMN"
DEV="/dev/mapper/$DMN"
DMQ="/sys/block/$(basename "$(readlink -f "$DEV")")/queue"
if ! echo 0 >"$DMQ/discard_max_bytes" 2>/dev/null || [ "$(cat "$DMQ/discard_max_bytes")" != 0 ]; then
    skip "3: cannot turn discard off on $DEV"
    ct_exit
fi
PROC="$(ct_procdir "$DEV")"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$MARK" | grep -q "UNMAP not supported by the device" && pass "3: the mount says the device takes no UNMAP" ||
    fail "3: the mount did not report the missing UNMAP support"
grep -q "^discard_supported: no" "$PROC/controls" && pass "3: controls says the device takes no discards" ||
    fail "3: controls still says discard_supported after the device lost it"
ERR0="$(info discard_errors)"
fill_and_delete
[ "$HANDED" -ge 1 ] && pass "3: emptied Block Groups are still handed back ($HANDED)" ||
    fail "3: only $HANDED Block Group(s) handed back -- a missing discard blocked the release"
[ "$(info discard_errors)" = "$ERR0" ] && pass "3: and nothing was attempted (no discard errors)" ||
    fail "3: discards were attempted on a device that has none"
if command -v fstrim >/dev/null; then
    T="$(fstrim -v "$MNT" 2>&1)" && fail "3: fstrim succeeded on a device with no discard: $T" ||
        { grep -qi "not supported" <<<"$T" && pass "3: fstrim reports the discard operation is not supported" ||
            fail "3: fstrim failed, but not as unsupported: $T"; }
fi
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "3: fsck clean" || fail "3: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
