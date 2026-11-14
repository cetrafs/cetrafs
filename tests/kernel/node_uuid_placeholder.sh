#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a placeholder DMI product UUID is refused as this node's identity, and the refusal names the way out
#
# The node identity is the DMI product UUID unless node_uuid overrides it.
# Firmware and hypervisors write placeholder values there (all zeros, all
# F, a sample value some releases ship), and the DMI path used them
# verbatim: two boards with the same placeholder became ONE node in the
# registry, sharing its row, its Zone Groups and its allocations (audit
# L7). A placeholder is now refused at registration, with a message that
# names node_uuid as the override.
#
# The firmware's value cannot be changed here, so the TEST ONLY selector
# dmi_uuid_inject puts a table entry in its place: 1 all zeros, 2 all F,
# 3 the firmware sample, 4 an ordinary identity.
#
#  A. each placeholder (1..3) is refused: the mount fails, nothing is
#     mounted, and the log names the placeholder and node_uuid
#  B. control: the ordinary identity (4) mounts, so the refusal is the
#     placeholder check and not a broken mount
#
# DISCRIMINATION: A fails with placeholder_ok on (the check removed --
# the placeholder mounts). NODE_UUID_NEGATIVE=1 sets it before A, and the
# suite must then FAIL at A: it is the negative control, run by hand.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 nodeuuidph)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nodeuuidph)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

# mount with the injected identity: RC of the mount, and the log since MARK
try_mount() { # <inject-index> -> sets RC and LOG
    local MARK
    ct_param_set dmi_uuid_inject "$1"
    MARK="$(dmesg_mark)"
    RC=0
    timeout 90 mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || RC=$?
    LOG="$(dmesg_since "$MARK")"
}

if [ "${NODE_UUID_NEGATIVE:-0}" = 1 ]; then
    log "NEGATIVE: the TEST ONLY placeholder_ok knob is set before A"
    ct_param_set placeholder_ok 1
fi

log "A: a placeholder identity is refused, and the refusal names node_uuid"
NAMES="all-zeros all-F firmware-sample"
k=1
for what in $NAMES; do
    try_mount "$k"
    if [ "$RC" != 0 ] && ! mountpoint -q "$MNT" &&
        grep -q 'is a placeholder' <<<"$LOG" && grep -q 'node_uuid=<uuid>' <<<"$LOG"; then
        pass "A: $what identity refused (mount exit $RC, nothing mounted, the log names node_uuid)"
    else
        fail "A: $what identity was not refused (mount exit $RC): $(grep cetrafs <<<"$LOG" | tail -2 | tr '\n' ' ')"
        mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
    fi
    k=$((k + 1))
done

log "B: control -- an ordinary identity mounts"
try_mount 4
if [ "$RC" = 0 ]; then
    require_cetrafs_mount "$MNT"
    pass "B: the ordinary identity mounted"
    ct_umount "$MNT"
else
    fail "B: the ordinary identity did not mount (exit $RC): $(grep cetrafs <<<"$LOG" | tail -2 | tr '\n' ' ')"
fi
ct_param_set dmi_uuid_inject 0
ct_param_set placeholder_ok 0
ct_exit
