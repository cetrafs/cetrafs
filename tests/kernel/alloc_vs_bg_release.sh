#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation that chose a Block Group never lands in it after the group was released
#
# The allocator picks a Block Group from owned_bgs, checks its Zone Group
# is ours, and only then takes alloc_mutex and sets the bit. The release
# of an empty Block Group drains it (clears its owned_bgs bit, under the
# same mutex), scans its bitmap, syncs it and hands it back by CAS. The
# drain only excluded an allocation already INSIDE the mutex: one that
# had chosen the group and not yet taken the mutex went on to allocate
# in a group this node had just given away. Its bit is set only in this
# node's cached bitmap, so the next owner reads the block FREE and hands
# it out again, and this node's later writeback puts its bitmap block
# back over the new owner's.
#
# One node is enough: the writer and the heartbeat's release are both
# local. alloc_pause_before_lock_ms holds the writer between its
# ownership check and alloc_mutex while the release runs.
#
# DISCRIMINATION: without the re-check under alloc_mutex the written
# block sits in a Block Group whose owner is FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535
MAP="$(ct_helper bg_map)"
EXTENT="$(ct_helper pending_poke)"
DEV="$(ct_dev 1700 avbr)"
MNT="$(ct_mnt avbr)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
compress_timing

bg_line() { "$MAP" "$DEV" | awk -v b="$1" '$1 == "bg" && $2 == b'; }
bg_field() { bg_line "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2}'; }
# bg_of <lba>: the Block Group whose span holds <lba> (largest start <= lba).
bg_of() {
    "$MAP" "$DEV" | awk -v l="$1" '$1 == "bg" {split($4,a,"="); if (a[2]+0 <= l+0 && a[2]+0 >= best) {best = a[2]+0; id = $2}} END {print id}'
}

nbg="$(ct_bgs_of_zg "$DEV" 0 | wc -l)"
[ "$nbg" -ge 3 ] || { fail "setup: only $nbg Block Groups in Zone Group 0"; ct_exit; }

# Keep every Block Group owned until the writer has chosen one.
ct_param_set bg_release_off 1
# One block per allocation: a run reservation would leave the chosen
# group non-empty for reasons of its own.
ct_param_set alloc_run_blocks 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Fill Block Group 0 (it holds the root directory's block, so the
# allocator's best-fit would keep choosing it) so the next allocation
# has to choose an EMPTY group -- the only kind a release hands back.
sync
umount "$MNT"
FREE0="$(bg_field 0 free | cut -d/ -f1)"
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/fill" bs=4096 count="$FREE0" conv=fsync status=none
sync
umount "$MNT"
FREE0="$(bg_field 0 free | cut -d/ -f1)"
[ "$FREE0" = 0 ] || { fail "setup: Block Group 0 still has $FREE0 free blocks -- the next pick may stay there"; ct_exit; }
released_before="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | wc -l)"
ct_mount "$DEV" "$MNT"

log "a writer chooses an empty Block Group and is held before alloc_mutex while the release runs"
ct_param_set alloc_pause_before_lock_ms 4000
dd if=/dev/urandom of="$MNT/victim" bs=4096 count=1 conv=fsync status=none &
WPID=$!
sleep 0.5
ct_param_set bg_release_off 0
wait "$WPID" || fail "the write failed"
ct_param_set bg_release_off 1
sync
INO="$(stat -c %i "$MNT/victim")"
umount "$MNT"

released_after="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | wc -l)"
[ "$released_after" -gt "$released_before" ] ||
    { fail "setup: no Block Group was released during the pause -- the race was not arranged"; ct_exit; }
pass "setup: $((released_after - released_before)) Block Group(s) released while the writer was held"

LBA="$("$EXTENT" "$DEV" extent "$INO" | cut -d' ' -f1)"
B="$(bg_of "$LBA")"
OWNER="$(bg_field "$B" owner_zg)"
log "victim block $LBA is in Block Group $B (owner_zg=$OWNER)"
if [ "$OWNER" = "$FREE_MARK" ]; then
    fail "the write landed in Block Group $B after it was released (owner FREE): the next owner would hand block $LBA out again"
else
    pass "the write landed in Block Group $B, owned by Zone Group $OWNER"
fi

if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck clean"
else
    fail "fsck reports damage"
fi

ct_exit
