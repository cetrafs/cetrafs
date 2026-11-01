#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag pass never stores a stale block count over a concurrent writer's
#
# The mover takes inode_lock + invalidate_lock per step and drops them
# between steps, so a writer may run in between -- by design. After the
# LAST step, with both locks dropped, it set i_blocks from that step's
# record: an append landing in that gap had its block counted by
# get_block, and then uncounted. The next publish carried the short
# count to the device (fsck does not cross-check it; du and stat do).
#
# defrag_final_stall_ms holds the gap open; one block is appended in it.
#
# DISCRIMINATION (measured on the unfixed code): st_blocks 512, not 520,
# in core and after remount. Each half of the fix alone still fails:
# the in-step store without the publish baseline, and the baseline with
# the unlocked store put back.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
N=64

DEV="$(ct_dev 560 dfblk)"
MNT="$(ct_mnt dfblk)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

for i in $(seq 0 $((N - 1))); do
    dd if=/dev/urandom of="$MNT/f" bs=4096 seek="$i" count=1 conv=notrunc status=none
    printf x >"$MNT/filler$i"
done
sync
ext="$(filefrag "$MNT/f" | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p')"
[ "${ext:-0}" -ge $((N / 2)) ] && pass "setup: the file has $ext extents" || { fail "setup: only '$ext' extents"; ct_exit; }

ct_param_set defrag_final_stall_ms 1500
"$ROOT/userspace/defrag.cetra" "$MNT/f" >/dev/null 2>&1 &
DPID=$!
sleep 0.7
# Append one block while the pass sits in its final gap.
dd if=/dev/urandom of="$MNT/f" bs=4096 seek=$N count=1 conv=notrunc status=none
wait "$DPID" || true
ct_param_set defrag_final_stall_ms 0
ext="$(filefrag "$MNT/f" | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p')"
[ "${ext:-99}" -le 3 ] && pass "setup: the pass ran ($ext extents now)" || { fail "setup: defrag did not run ($ext extents)"; ct_exit; }

want=$(((N + 1) * 8))
got="$(stat -c %b "$MNT/f")"
[ "$got" = "$want" ] && pass "in core: st_blocks $got counts the appended block" ||
    fail "in core: st_blocks $got, expected $want -- the pass overwrote the writer's count"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
got="$(stat -c %b "$MNT/f")"
[ "$got" = "$want" ] && pass "on disk: st_blocks $got after remount" ||
    fail "on disk: st_blocks $got after remount, expected $want"
ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
