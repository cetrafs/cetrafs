#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# -o discard: space freed inside a Block Group this node keeps goes back to the device
#
# The hand-back discards a Block Group as it leaves for the pool, and
# fstrim trims what an operator asks for. Neither touches a hole punched
# in a VM image whose group stays in use -- a guest's TRIM -- until
# someone runs fstrim. With `-o discard` each run freed in a group this
# node owns is queued, and a worker discards it a moment later through
# fstrim's own claim -> discard -> give-back (discard.c, inline discard).
#
# The oracle is the loop device's backing file, as in discard_handback.sh:
# a loop device implements discard by punching the image, so `du` on it
# is "did the space come back".
#
#  1. -o discard: punch 32 MiB out of the middle of a 64 MiB file (its
#     Block Group keeps the rest, so it never goes back to the pool); the
#     image shrinks by about that, the worker counts its discards, and no
#     hand-back happened that could explain it.
#  2. NEGATIVE CONTROL -- no option: the same punch, and the image does
#     NOT shrink. Proves the drop in 1 is the inline discard.
#  3. the switch: `inline_discard=off` in controls, then the same punch:
#     nothing queued, nothing shrinks; and `discard=off` (the hand-back
#     switch) turns the inline one off too.
#  4. a second mount of the device stating `discard` when the mount does
#     not have it is refused, as for the other options.
# fsck clean after each.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in inline_discard_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

IMG="$(ct_big_image 1200 idisc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt idisc)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set inline_discard_delay_ms 200

used_kb() { du -k "$IMG" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/info"; }
ctl() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/controls"; }
mnt() { # [extra -o]
    local o="${CT_MOUNT_OPTS:-}"
    [ -n "${1:-}" ] && o="${o:+$o,}$1"
    CT_MOUNT_OPTS="$o" ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
}

# punch_round <tag> <mount option>: a 64 MiB file, 32 MiB punched out of
# its middle. Sets BEFORE, AFTER (image KiB), DQ/DC/DB (the inline
# counters' deltas), HB (hand-back discards during the round).
punch_round() {
    local q0 c0 b0 h0 i
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    mnt "$2"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=64 conv=fsync status=none
    sync
    sleep 1 # whatever the write itself gave back (its unused preallocation) is worked off first
    BEFORE="$(used_kb)"
    q0="$(info inline_discard_queued)"; c0="$(info inline_discard_cmds)"
    b0="$(info inline_discard_blocks)"; h0="$(info discard_handback_bgs)"
    fallocate -p -o $((16 << 20)) -l $((32 << 20)) "$MNT/f"
    sync
    for i in $(seq 1 30); do
        [ "$(info inline_discard_blocks)" -ge $((b0 + 8192)) ] && break
        sleep 0.2
    done
    sleep 0.5
    AFTER="$(used_kb)"
    DQ=$(($(info inline_discard_queued) - q0))
    DC=$(($(info inline_discard_cmds) - c0))
    DB=$(($(info inline_discard_blocks) - b0))
    HB=$(($(info discard_handback_bgs) - h0))
}

fsck_clean() {
    local out
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: fsck clean" || fail "$1: fsck: $(grep -m3 '^ERR' <<<"$out")"
}

# ------------------------------------------------------------------- 1
log "1: -o discard"
punch_round 1 discard
[ "$(ctl inline_discard)" = on ] && pass "1: controls says inline_discard: on" ||
    fail "1: controls says inline_discard: $(ctl inline_discard)"
[ "$DQ" -ge 1 ] || { fail "1 setup: the punch queued nothing ($DQ)"; ct_exit; }
[ "$HB" = 0 ] || { fail "1 setup: a hand-back discard ran ($HB) -- the oracle would not isolate the inline one"; ct_exit; }
[ "$DB" -ge 8192 ] && pass "1: the worker discarded $DB blocks in $DC command(s) for $DQ queued range(s)" ||
    fail "1: the worker discarded $DB blocks ($DC commands) of the 8192 punched"
[ $((BEFORE - AFTER)) -ge $((30 * 1024)) ] && pass "1: the image shrank by $((BEFORE - AFTER)) KiB" ||
    fail "1: the image went $BEFORE -> $AFTER KiB: the space did not come back"
fsck_clean 1

# ------------------------------------------------------------------- 2
log "2: NEGATIVE CONTROL -- no option"
punch_round 2 ""
[ "$(ctl inline_discard)" = off ] || fail "2 setup: inline_discard is $(ctl inline_discard) without the option"
[ "$DQ" = 0 ] && [ "$DB" = 0 ] && pass "2: nothing queued, nothing discarded" || fail "2: queued $DQ, discarded $DB"
[ $((BEFORE - AFTER)) -lt 1024 ] && pass "2: the image did not shrink ($BEFORE -> $AFTER KiB): 1's drop is the inline discard" ||
    fail "2: the image shrank by $((BEFORE - AFTER)) KiB without inline discard -- 1 proves nothing"
fsck_clean 2

# ------------------------------------------------------------------- 3
log "3: the controls"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mnt discard
PROC="$(ct_procdir "$DEV")"
dd if=/dev/urandom of="$MNT/f" bs=1M count=32 conv=fsync status=none
sync
echo "inline_discard=off" >"$PROC/controls"
Q0="$(info inline_discard_queued)"
fallocate -p -o 0 -l $((8 << 20)) "$MNT/f"
sync
[ "$(info inline_discard_queued)" = "$Q0" ] && pass "3: inline_discard=off: the punch queued nothing" ||
    fail "3: inline_discard=off still queued $(($(info inline_discard_queued) - Q0))"
echo "inline_discard=on" >"$PROC/controls"
echo "discard=off" >"$PROC/controls"
fallocate -p -o $((8 << 20)) -l $((8 << 20)) "$MNT/f"
sync
[ "$(info inline_discard_queued)" = "$Q0" ] && pass "3: discard=off turns the inline discard off too" ||
    fail "3: discard=off still queued $(($(info inline_discard_queued) - Q0))"
echo "discard=on" >"$PROC/controls"
fallocate -p -o $((16 << 20)) -l $((8 << 20)) "$MNT/f"
sync
[ "$(info inline_discard_queued)" -gt "$Q0" ] && pass "3 contrast: both on again, the next punch queues" ||
    fail "3 contrast: both on and nothing queued -- the two cases above prove nothing"

# ------------------------------------------------------------------- 4
log "4: a second mount stating discard"
MNT2="$(ct_mnt idisc2)"
echo "inline_discard=off" >"$PROC/controls"
if mount -t cetrafs -o discard "$DEV" "$MNT2" 2>/dev/null; then
    ct_track mnt "$MNT2"
    fail "4: a second mount asking for discard was accepted while the mount has it off"
    umount "$MNT2" || true
else
    pass "4: a second mount asking for discard is refused while the mount has it off"
fi
echo "inline_discard=on" >"$PROC/controls"
if mount -t cetrafs -o discard "$DEV" "$MNT2" 2>/dev/null; then
    ct_track mnt "$MNT2"
    pass "4 contrast: and accepted while it is on"
    umount "$MNT2"
else
    fail "4 contrast: refused even with discard on -- the refusal above proves nothing"
fi
fsck_clean 3
ct_exit
