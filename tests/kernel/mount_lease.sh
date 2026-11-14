#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the lease runs from the mount's registration, not from the heartbeat's first tick
#
# The in-core lease was armed by the heartbeat's first renewal. Every
# mount phase before it -- the own-claim sweep, the Zone Group claim and
# recount, the mount-time drain -- wrote with no lease at all, and those
# phases scale with the volume (minutes on a large one). Past the peers'
# window they reclaim from the mount while it goes on writing (audit
# 2026-11-14 F1). Registration is a beat: the lease now runs from it,
# and the long phases renew it (cetrafs_sb_mount_beat()).
#
# A mount on a 1 s beat (a 3 s lease) is held 6 s right after it
# registers (mount_post_register_stall_ms), as a slow sweep would hold
# it: it must come up stopped, or not at all -- never writing.
#
# DISCRIMINATION: lease_disable leaves the lease unarmed, as the
# heartbeat's first renewal used to; the same mount then comes up
# writing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in mount_post_register_stall_ms lease_disable; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
# One device per run: the refused mount's row stays registered, and a
# later mkfs on the same device would watch it out first.
DEVS=("$(ct_loop "$(ct_image 560 mlease0)")" "$(ct_loop "$(ct_image 560 mlease1)")")
MNT="$(ct_mnt mlease)"
ct_track mnt "$MNT"
compress_timing
ct_param_set lease_disable 0
ct_param_set mount_post_register_stall_ms 0

# <lease_disable 0|1> -> "up-and-writing" | "stopped" | "refused"
probe() {
    DEV="${DEVS[$1]}"
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set lease_disable "$1"
    ct_param_set mount_post_register_stall_ms 6000
    if ! mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        echo refused
    elif [ "$(sed -n 's/^fenced: //p' "$(ct_procdir "$DEV")/info")" = yes ] ||
        ! { echo x >"$MNT/f" && sync "$MNT/f"; } 2>/dev/null; then
        echo stopped
    else
        echo up-and-writing
    fi
    umount "$MNT" 2>/dev/null || true
    ct_param_set mount_post_register_stall_ms 0
    ct_param_set lease_disable 0
}

R="$(probe 0)"
[ "$R" != up-and-writing ] && pass "a mount held past its lease after registering comes up $R, not writing" ||
    fail "a mount held 6 s past a 3 s lease after registering came up writing -- it ran unleased"
R="$(probe 1)"
[ "$R" = up-and-writing ] && pass "control: with the lease unarmed the same mount comes up writing -- the suite discriminates" ||
    fail "control: with lease_disable the mount came up $R -- the suite cannot tell"
ct_exit
