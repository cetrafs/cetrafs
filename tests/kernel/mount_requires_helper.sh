#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount that did not come through mount.cetrafs's transport check is refused
#
# mount.cetrafs checks that this node's queued writes cannot reach the
# array after its lease is gone -- multipath queueing, transport timers
# (audit 2026-11-14 A-6, 2026-11-15 B-20). mount(8) runs it for
# `mount -t cetrafs`, but a mount that skipped it -- `mount -i`, a direct
# mount(2), a node with the module and not the tools -- joined the
# cluster unchecked (audit 2026-11-15 A-6). The helper now says
# transport_checked and the module refuses a mount without it.
#
# With require_mount_check=1 (the module's default; the harness loads
# with 0):
#   1. `mount -i -t cetrafs`: refused, saying why;
#   2. through mount.cetrafs (a loop device: no transport to hold
#      anything): mounted;
#   3. `mount -i -o transport_checked`, said on purpose: mounted.
#
# DISCRIMINATION: require_mount_check=0 (no gate, as before): 1 mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/require_mount_check ] || { skip "require_mount_check is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
HELPER="$ROOT/userspace/mount.cetrafs"
DEV="$(ct_dev 560 mrh)"
MNT="$(ct_mnt mrh)"
ct_track mnt "$MNT"
ct_param_set require_mount_check 0
ct_mkfs_small "$DEV" >/dev/null

# try <require 0|1> <how: plain|helper|vouched> -> "rc=<n> mounted=<yes|no>"
try() {
    local rc=0 m=no
    echo "$1" >$P/require_mount_check
    case "$2" in
    plain) mount -i -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$? ;;
    helper) "$HELPER" "$DEV" "$MNT" 2>/dev/null || rc=$? ;;
    vouched) mount -i -t cetrafs -o transport_checked "$DEV" "$MNT" 2>/dev/null || rc=$? ;;
    esac
    mountpoint -q "$MNT" && { m=yes; umount "$MNT"; }
    echo 0 >$P/require_mount_check
    echo "rc=$rc mounted=$m"
}

MARK="$(dmesg_mark)"
R1="$(try 1 plain)"
[ "${R1#*mounted=}" = no ] && dmesg_since "$MARK" | grep -q "did not come through mount.cetrafs" &&
    pass "1: a mount that skipped mount.cetrafs: refused, and said why" || fail "1: $R1"
R2="$(try 1 helper)"
[ "$R2" = "rc=0 mounted=yes" ] && pass "2: through mount.cetrafs: mounted" || fail "2: $R2"
R3="$(try 1 vouched)"
[ "$R3" = "rc=0 mounted=yes" ] && pass "3: transport_checked given on purpose: mounted" || fail "3: $R3"
C="$(try 0 plain)"
[ "$C" = "rc=0 mounted=yes" ] && pass "control: with the gate off, the unchecked mount went through" ||
    fail "control: $C -- the suite does not reach the gate"
ct_exit
