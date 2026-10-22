#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the device's CAW capability is discovered honestly, or the mount fails
#
# cetrafs_sb_caw_available() reads one field -- max_caw_blocks -- to
# decide whether this volume has cross-node atomicity at all. Everything
# rests on that answer: whether fs.c's mount gate runs, whether the CAS
# takes the atomic path or the serialised fallback, whether a free aimed
# at a foreign Zone Group may be applied directly.
#
# So the two ways of getting it wrong both matter, and neither used to be
# covered:
#
#  * Claiming a capability that does not exist. Discovery reported the
#    kernel's atomic-write unit as max_caw_blocks for NVMe, whose CAW
#    backend is a stub returning -EOPNOTSUPP. The volume looked
#    multi-node-safe (gate skipped) while every compare-and-swap failed.
#    Not reachable on this host -- there is no NVMe device here -- so the
#    invariant is asserted where it can be: a class with no working
#    backend must report 0.
#  * Treating "could not determine" as "no CAW". A failed probe left the
#    struct zeroed, which reads as no-CAW, and the mount carried on with
#    a pr_warn. On a shared LUN that silently puts this node on the
#    fallback -- no cross-node atomicity -- while a peer whose probe
#    succeeded uses real CAS and believes it is protected.
#
# Measured discrimination: reverting the mount-refusal fix fails exactly
# the two refusal assertions (the old code warned and mounted anyway).
# The two capability assertions pass either way here -- the loop device
# genuinely has no CAW, and the NVMe case they are really aimed at has no
# hardware on this host -- so they are invariant statements, not
# discriminators. Treat them as such.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FAIL_PARAM=/sys/module/cetrafs/parameters/caw_fail_discover
restore_discover() {
    [ -w "$FAIL_PARAM" ] && echo 0 >"$FAIL_PARAM"
    return 0
}

DEV="$(ct_dev 560 cawdisc)"
MNT="$(ct_mnt cawdisc)"
ct_mkfs_small "$DEV" >/dev/null

log "checking a device with no atomic CAW is reported as having none"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CAW_LINE="$(dmesg_since "$MARK" | grep -o 'CAW: class=.*' | head -1)"
if echo "$CAW_LINE" | grep -q 'max_caw_blocks=0 -> atomic CAS unavailable'; then
    pass "caw: a loop device reports no atomic CAW ($CAW_LINE)"
else
    fail "caw: expected max_caw_blocks=0 / unavailable on a loop device, got: ${CAW_LINE:-<no line>}"
fi
# The invariant the NVMe bug violated: anything that cannot execute a
# compare-and-swap must report a length of zero, not a hardware ceiling.
if echo "$CAW_LINE" | grep -qE 'class=(none|nvme) .*max_caw_blocks=[1-9]'; then
    fail "caw: a class with no working CAW backend is advertising a nonzero length: $CAW_LINE"
else
    pass "caw: no class without a working backend advertises a usable CAW length"
fi
ct_umount "$MNT"

log "checking a mount is REFUSED when the capability cannot be determined"
echo 1 >"$FAIL_PARAM"
MARK2="$(dmesg_mark)"
MOUNT_RC=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || MOUNT_RC=$?
restore_discover
if [ "$MOUNT_RC" = "0" ]; then
    umount "$MNT"
    fail "caw: the mount succeeded despite discovery failing -- it assumed no-CAW instead of stopping"
else
    pass "caw: the mount was refused when discovery failed (rc=$MOUNT_RC)"
fi
if dmesg_since "$MARK2" | grep -q "refusing the mount rather than"; then
    pass "caw: dmesg explains the refusal"
else
    fail "caw: no explanation in dmesg for the refused mount"
fi

log "checking the volume mounts normally again once discovery works"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    pass "caw: the same volume mounts again with discovery restored"
    umount "$MNT"
else
    fail "caw: the volume no longer mounts after the forced-failure case"
fi

ct_exit
