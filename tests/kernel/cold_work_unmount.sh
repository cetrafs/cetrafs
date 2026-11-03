#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a queued cold-tree reconcile pinning a deleted file is run before unmount evicts, not after put_super
#
# When a peer republishes a file's layout, the freshness gate marks our
# cached tree cold and queues a reconcile that holds an igrab()
# reference. It was queued on the system workqueue, which unmount knows
# nothing about: evict_inodes() skipped the inode the work pinned, put_super
# freed the mount's state, and the work's iput() -- the LAST reference
# of a file deleted meanwhile -- evicted it afterwards and went to free
# its blocks through a NULL sb_info. Reported from the field on 0.9.3 as
# an Oops in cetrafs_inode_cold_work right after "unmounted", on a node
# whose VMs had just been destroyed.
#
# Now the reconcile runs on a per-mount queue that kill_sb closes and
# flushes before the VFS evicts anything, so that iput() evicts the file
# while the mount is whole and frees its blocks as any unlink would.
#
# The reconcile is held with cold_work_stall_ms so it is still queued,
# pinning the deleted file, when umount starts.
#
# DISCRIMINATION: without the change the umount returns at once with
# "Busy inodes after unmount" and the work Oopses seconds later, so the
# negative control belongs on a disposable machine: the timing and the
# busy-inode assertions are the ones that fail first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/cold_work_stall_ms ] || { skip "cold_work_stall_ms is missing"; ct_exit; }

IPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_dev 560 coldumount)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt coldumount)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }

dd if=/dev/urandom of="$MNT/vm.raw" bs=4096 count=64 status=none
sync
INO="$(stat -c %i "$MNT/vm.raw")"
exec 3<"$MNT/vm.raw" # an opener, so the next open asks the gate

STALL=3000
ct_param_set cold_work_stall_ms "$STALL"
D0="$(info file_cache_drops)"
"$IPOKE" "$BACK" peerseq "$INO" 5 >/dev/null # a peer republished the layout
blockdev --flushbufs "$DEV"
cat "$MNT/vm.raw" >/dev/null # the gate sees it: mark cold, queue the reconcile
rm "$MNT/vm.raw"
exec 3<&- # now only the queued reconcile holds the inode
cold_worker() { grep -l cetrafs_inode_cold_work /proc/[0-9]*/stack 2>/dev/null | head -1; }
if [ "$(info file_cache_drops)" -gt "$D0" ] && [ -n "$(cold_worker)" ]; then
    pass "setup: a reconcile is queued and still held, pinning the deleted file"
else
    fail "setup: drops $D0 -> $(info file_cache_drops), no worker in cetrafs_inode_cold_work"
    ct_param_set cold_work_stall_ms 0
    ct_exit
fi

MARK="$(dmesg_mark)"
T0="$(date +%s%N)"
ct_umount "$MNT"
MS=$((($(date +%s%N) - T0) / 1000000))
ct_param_set cold_work_stall_ms 0
sleep $((STALL * 2 / 1000 + 1)) # where the unfixed work would wake

[ "$MS" -ge $((STALL * 2 - 500)) ] && pass "umount waited for the reconcile (${MS} ms)" ||
    fail "umount returned in ${MS} ms, with the reconcile still queued"
dmesg_since "$MARK" | grep -q "Busy inodes after unmount" &&
    fail "the VFS found an inode still pinned after unmount: $(dmesg_since "$MARK" | grep -m1 'Busy inodes')" ||
    pass "no busy inode left behind"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" &&
    fail "fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)" ||
    pass "fsck clean: the deleted file's inode and blocks were freed at unmount"
ct_exit
