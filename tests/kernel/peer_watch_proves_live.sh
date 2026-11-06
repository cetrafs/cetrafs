#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount's peer checks take a registry row as live only once it beats
#
# Before registering, a mount asks the registry two things: does a live
# node run this volume without atomic CAW, and which file-lock mode does
# the live cluster run? "Live" went through the staleness watch, whose
# first sample of any row answers "alive" -- and at mount there is no
# earlier sample, and a refused mount frees the watch. A row left by a
# node that crashed was therefore live on every attempt, forever (audit
# 2026-11-06 M5):
#   (A) a crashed no-CAW node blocked every CAW mount with EBUSY;
#   (B) a crashed lock-on cluster refused `-o nofilelock` with EINVAL;
#   (C) a crashed nofilelock cluster handed its mode to the next default
#       mount.
# Each wanted row is now watched until it beats or the window ends; one
# that never moves is dead, imposes nothing, and is recorded as departed.
#
# Staged on a CAW-assumed mount (the no-CAW gate watches every row on its
# own, which would hide the fault): row 1 is planted REGISTERED with a
# fresh last_seen, and either left still (dead) or beating every second
# through ct_beat_row (live). A compressed stale window keeps the watch short.
#
# DISCRIMINATION: with the walk judging by the first sample, each dead
# case binds the mount as if the row were live. The beating cases are the
# other half: a watch that called everything dead would pass the first
# three and fail these.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/mount_assume_caw ] || { skip "mount_assume_caw is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
DEV="$(ct_dev 560 pwatch)"
MNT="$(ct_mnt pwatch)"
ct_mkfs_small "$DEV" >/dev/null
set_stale_window "$TEST_STALE_SECS" # the watch is the stale window
ct_param_set mount_assume_caw 1

plant() { # <caps> <mode>
    "$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null
    "$NODE_POKE" "$DEV" 1 --caps "$1" >/dev/null
    "$NODE_POKE" "$DEV" 1 --mode "$2" >/dev/null
}
row1() { "$NODE_POKE" "$DEV" 1; }
flock_mode() { sed -n 's/^file_lock: //p' "$(ct_procdir "$DEV")/info"; }
try_mount() { # [opts] -> 0 mounted, else the mount's status
    if mount -t cetrafs ${1:+-o "$1"} "$DEV" "$MNT" 2>/dev/null; then
        ct_track mnt "$MNT"
        return 0
    fi
    return 1
}

# ------------------------------------------------ (A) a no-CAW row
plant 0x3 1
grep -q 'last_seen=0 ' <<<"$(row1)" && { fail "setup: the planted row reads departed"; ct_exit; }
MARK="$(dmesg_mark)"
if try_mount; then
    pass "(A) a dead no-CAW row did not block a CAW mount"
    ct_umount "$MNT"
    grep -q 'last_seen=0 ' <<<"$(row1)" && pass "(A) the dead row was recorded as departed" ||
        fail "(A) the dead row was not recorded as departed: $(row1)"
else
    fail "(A) a dead no-CAW row blocked the mount: $(dmesg_since "$MARK" | grep -m1 -i 'cetrafs.*\(refus\|without\)')"
fi
plant 0x3 1
ct_beat_row "$DEV" 1
MARK="$(dmesg_mark)"
if try_mount; then
    fail "(A, live) a CAW mount went ahead beside a beating no-CAW row"
    ct_umount "$MNT"
else
    dmesg_since "$MARK" | grep -q 'without atomic CAW' && pass "(A, live) a beating no-CAW row still refuses a CAW mount" ||
        fail "(A, live) the mount failed, but not for the no-CAW peer"
fi
ct_unbeat

# ------------------------------------------------ (B) a lock-on row, -o nofilelock
plant 0x1 1
if try_mount nofilelock; then
    [ "$(flock_mode)" = off ] && pass "(B) a dead lock-on row did not refuse -o nofilelock" ||
        fail "(B) mounted, but the file lock reads '$(flock_mode)'"
    ct_umount "$MNT"
else
    fail "(B) a dead lock-on row refused -o nofilelock"
fi
plant 0x1 1
ct_beat_row "$DEV" 1
MARK="$(dmesg_mark)"
if try_mount nofilelock; then
    fail "(B, live) -o nofilelock mounted beside a beating lock-on row"
    ct_umount "$MNT"
else
    dmesg_since "$MARK" | grep -q 'conflicts with this cluster' && pass "(B, live) a beating lock-on row still refuses -o nofilelock" ||
        fail "(B, live) the mount failed, but not for the mode"
fi
ct_unbeat

# ------------------------------------------------ (C) a nofilelock row, default mount
plant 0x1 2
if try_mount; then
    [ "$(flock_mode)" = on ] && pass "(C) a dead nofilelock row did not hand its mode to a default mount" ||
        fail "(C) a default mount inherited '$(flock_mode)' from a dead row"
    ct_umount "$MNT"
else
    fail "(C) a default mount was refused beside a dead nofilelock row"
fi
plant 0x1 2
ct_beat_row "$DEV" 1
if try_mount; then
    [ "$(flock_mode)" = off ] && pass "(C, live) a beating nofilelock row's mode is inherited" ||
        fail "(C, live) a default mount ran '$(flock_mode)' beside a live nofilelock cluster"
    ct_umount "$MNT"
else
    fail "(C, live) a default mount was refused beside a beating nofilelock row"
fi
ct_unbeat
ct_exit
