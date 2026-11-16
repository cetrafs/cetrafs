#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a deferred namespace settle keeps the superblock until it has finished
#
# A namespace operation that must recount a dead holder's lock defers it
# to task work, run as the task returns to user space, after the call has
# dropped its path (nslock_settle_outside_vfs.sh). The work held its
# inode and nothing else: a lazy unmount during it tore the superblock
# down underneath -- kill_sb found the inode busy, put_super freed
# sb_info, and the work went on to acquire and iput() through it (rule
# 20, the 0.9.3 field Oops's shape). It now holds the superblock active
# until it has dropped the inode, and the unmount finishes there.
#
# Row 1, dead, holds d's namespace lock; a create in d takes it over and
# defers the recount, whose work is held 5 s (nslock_settle_stall_ms).
# 1 s in, umount -l:
#   1. the mount's state is still there while the work runs;
#   2. it is gone once the work has finished, and no inode was busy;
#   3. the volume checks clean.
#
# DISCRIMINATION: NSU_UNPINNED=1 (nslock_defer_unpinned) -- the
# superblock is gone at step 1 and "Busy inodes after unmount". The work
# then says so and touches nothing, but the inode it held is leaked, and
# the module's inode cache with it, so the control is run by hand, not
# here (it was, when the change was made).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 nssetum)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nssetum)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_replay_sweep_off 1
ct_param_set nslock_settle_in_vfs 0
ct_param_set nslock_defer_unpinned "${NSU_UNPINNED:-0}"
ct_param_set nslock_settle_stall_ms 0
info() { sed -n "s/^$1: //p" "$PROC/info"; }

ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 8 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
echo hb_interval_secs=5 >"$PROC/controls"
echo stale_secs=15 >"$PROC/controls"
mkdir "$MNT/d"
: >"$MNT/d/a"
sync
poke_dead_peer "$DEV" 1 a1
"$NPOKE" "$DEV" 1 --stale 15 >/dev/null
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/d")" --ns 1 >/dev/null
wait_for 60 "grep -q '^node 1: .*stale=yes' '$PROC/cluster'" || { fail "setup: row 1 never went stale"; ct_exit; }
n0="$(info nslock_settle_deferred)"
echo 5000 >/sys/module/cetrafs/parameters/nslock_settle_stall_ms
MARK="$(dmesg_mark)"
touch "$MNT/d/new" 2>/dev/null &
pid=$!
sleep 1
[ "$(info nslock_settle_deferred)" -gt "$n0" ] || { fail "setup: the create did not defer its recount"; ct_exit; }
umount -l "$MNT"
sleep 1
[ -d "$PROC" ] && pass "1: the mount's state is still there while the deferred work runs" ||
    fail "1: the superblock was torn down under the deferred work"
wait "$pid" || true
echo 0 >/sys/module/cetrafs/parameters/nslock_settle_stall_ms
wait_for 30 "[ ! -d '$PROC' ]" || true
[ ! -d "$PROC" ] && ! dmesg_since "$MARK" | grep -q "Busy inodes" &&
    pass "2: the unmount finished after the work, with no inode busy" ||
    fail "2: proc=$([ -d "$PROC" ] && echo left || echo gone) busy=$(dmesg_since "$MARK" | grep -c 'Busy inodes')"
"$NPOKE" "$DEV" 1 --depart 1 >/dev/null
blockdev --flushbufs "$DEV"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "3: fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "3: fsck clean"
ct_exit
