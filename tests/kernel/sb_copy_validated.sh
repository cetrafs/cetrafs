#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the mount reads the superblock it validated, not the buffer it came from
#
# fill_super validated the superblock in the live buffer, copied it
# later into raw_sb, and went on reading fields straight from the buffer
# after that -- the BG table chain, the root inode number. Anything that
# replaces the buffer in between (a forced-fresh re-read, a peer's
# growfs) hands the mount values nobody checked (audit 2026-11-06 L14).
# Every check and every later read now uses one private copy.
#
# Staged with sb_scribble_once: right after validation the cached
# superblock's root_ino is zeroed. The mount must still succeed and see
# its root.
#
# DISCRIMINATION: reading the buffer, the mount looks up inode 0 as the
# root and fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/sb_scribble_once ] || { skip "sb_scribble_once is missing"; ct_exit; }

DEV="$(ct_dev 560 sbcopy)"
MNT="$(ct_mnt sbcopy)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo hello >"$MNT/f"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"

ct_param_set sb_scribble_once 1
RC=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || RC=$?
LEFT="$(cat /sys/module/cetrafs/parameters/sb_scribble_once)"
ct_param_set sb_scribble_once 0
[ "$LEFT" = N ] || { fail "setup: the mount never reached the scribble"; mountpoint -q "$MNT" && umount "$MNT"; ct_exit; }
if [ "$RC" = 0 ]; then
    require_cetrafs_mount "$MNT"
    [ "$(cat "$MNT/f" 2>/dev/null)" = hello ] && pass "the mount used the superblock it validated: root and data are there" ||
        fail "the mount succeeded but its root is wrong"
    umount "$MNT"
else
    fail "the mount read the superblock buffer after validating it, and failed (rc $RC)"
fi
blockdev --flushbufs "$DEV" # the scribbled clean buffer goes
ct_exit
