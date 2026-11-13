#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a ZG record copy is never torn by a same-node patch of its cached block
#
# cetrafs_read_zg() checks a Zone Group record's checksum on the live
# cached buffer and copies it afterwards. A claim, release or free-count
# flush of the record patches that buffer in place (cetrafs_cache_region_
# after_cas()) right after its CAS lands. Unlocked, a patch landing between
# the check and the copy hands out a half-old, half-new image the checksum
# never saw. Under the buffer lock the patch waits for the copy.
#
# The rig makes that interleaving deterministic:
#   zg_read_gap_ms      pauses the reader between its check and its copy;
#   zg_read_unlocked    the control: check and copy without the lock;
#   zg_patch_stall_ms   a one-shot stall, held halfway through the next
#                       in-place patch of a ZG table block (the patch holds
#                       the buffer lock across it);
# and the trigger is a free-count flush of this node (a write with fsync),
# while a statfs reader keeps reading that ZG record.
#
# A patch that starts inside the reader's gap tears the copy whenever the
# stall outlasts the gap, so the control must tear: zg_copy_torn climbs.
# The copy is checked against its own checksum after the memcpy; a copy
# that fails is counted (zg_copy_torn) and read again, never returned.
#
# Both phases run on each device: the control first (it must tear, or the
# rig cannot discriminate), then the locked reader (zero torn copies). The
# LIO disk always runs. The shared LUN runs only when CT_CAW_DEV names it,
# and is formatted by this suite: its contents are scratch.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in zg_read_gap_ms zg_read_unlocked zg_patch_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

ROUNDS=4
STALL_MS=1500
GAP_MS=300

# Set by phase(): the copies torn during it.
TORN_DELTA=0
MNT=""
INFO=""

torn() { sed -n 's/^zg_copy_torn: //p' "$INFO"; }
corrupt() { sed -n 's/^corruptions: //p' "$INFO"; }
stall_left() { cat /sys/module/cetrafs/parameters/zg_patch_stall_ms; }

# One phase: a statfs reader and the trigger run together until the reader
# is stopped. Sets TORN_DELTA. <unlocked 0|1>.
phase() {
    local name="$1" unlocked="$2" t0 t1 i k taken RUNF READER
    ct_param_set zg_read_unlocked "$unlocked"
    ct_param_set zg_read_gap_ms "$GAP_MS"
    RUNF="$(ct_tmp zgtorn-run)"
    # The reader stops when RUNF is removed; ct_tmp tracks it, so cleanup
    # also stops a reader that outlives a failed run.
    (
        while [ -e "$RUNF" ]; do
            stat -f "$MNT" >/dev/null 2>&1 || true
            cat "$INFO" >/dev/null 2>&1 || true
            sleep 0.02
        done
    ) &
    READER=$!
    sleep 0.3
    t0="$(torn)"
    for i in $(seq 1 "$ROUNDS"); do
        # The stall is one-shot: armed, then taken by the next ZG table
        # patch. The trigger is retried a few times; the knob reading 0
        # again is the proof that a patch ran under it.
        taken=0
        for k in 1 2 3 4 5; do
            ct_param_set zg_patch_stall_ms "$STALL_MS"
            dd if=/dev/zero of="$MNT/zt-$name-$i-$k" bs=4096 count=2 conv=fsync status=none 2>/dev/null || true
            if [ "$(stall_left)" = 0 ]; then
                taken=1
                break
            fi
        done
        if [ "$taken" != 1 ]; then
            rm -f "$RUNF"
            wait "$READER" || true
            fail "setup: round $i never reached a ZG table patch -- nothing was stalled, so this measures nothing"
            ct_exit
        fi
    done
    rm -f "$RUNF"
    wait "$READER" || true
    t1="$(torn)"
    TORN_DELTA=$((t1 - t0))
    log "$name (unlocked=$unlocked): $ROUNDS stalled patches, zg_copy_torn $t0 -> $t1"
}

rig() { # <device> <tag>: one node, one volume on <device>
    local DEV="$1" tag="$2" C0 C1 CTRL LOCK
    MNT="$(ct_mnt "zgtorn-$tag")"
    INFO="$(ct_procdir "$DEV")/info"
    if [ "$tag" = real ]; then
        ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -s 2G -f >/dev/null
    else
        ct_mkfs_small "$DEV" >/dev/null
    fi
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    grep -q 'available=yes' "$(ct_procdir "$DEV")/properties" ||
        { fail "setup: the $tag device is not driven with CAW"; ct_exit; }
    ct_param_set auto_defrag 0
    C0="$(corrupt)"

    phase control 1
    CTRL="$TORN_DELTA"
    phase locked 0
    LOCK="$TORN_DELTA"

    ct_param_set zg_read_unlocked 0
    ct_param_set zg_read_gap_ms 0
    ct_param_set zg_patch_stall_ms 0
    C1="$(corrupt)"

    [ "$CTRL" -ge 1 ] && pass "$tag control: copied without the lock, a stalled patch tore $CTRL ZG copy(ies)" ||
        fail "$tag control: no ZG copy was torn -- the rig did not discriminate, the locked result below proves nothing"
    [ "$LOCK" = 0 ] && pass "$tag locked: no ZG copy was torn under the buffer lock" ||
        fail "$tag locked: $LOCK ZG copy(ies) torn under the buffer lock"
    [ "$C1" = "$C0" ] && pass "$tag: no damage counted" ||
        fail "$tag: $((C1 - C0)) corruption(s) counted"

    ct_umount "$MNT"
    if ct_fsck "$DEV" >/dev/null; then pass "$tag: fsck clean"; else fail "$tag: fsck reports damage"; fi
}

WHY="$(ct_tmp zgtorn-why)"
IMG="$(ct_image 560 zgtorn)"
if DEV="$(ct_lio_disks "$IMG" 1 2>"$WHY")"; then
    rig "$DEV" lio
else
    skip "LIO disk: $(cat "$WHY")"
fi

if [ -n "${CT_CAW_DEV:-}" ]; then
    [ -b "$CT_CAW_DEV" ] || { fail "CT_CAW_DEV is not a block device"; ct_exit; }
    if findmnt -rn -S "$CT_CAW_DEV" >/dev/null 2>&1; then
        fail "CT_CAW_DEV is already mounted"
        ct_exit
    fi
    rig "$CT_CAW_DEV" real
else
    skip "CT_CAW_DEV unset: the shared-LUN run is not made"
fi
ct_exit
