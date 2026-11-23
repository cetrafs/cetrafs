#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an allocation whose Block Group was released before it read the descriptor chooses again
#
# The allocator picks a Block Group from owned_bgs, reads its
# descriptor, and checks the descriptor's Zone Group is ours. A release
# landing between the pick and the read leaves the descriptor naming no
# Zone Group at all, and the check answered -EPERM with "refusing to
# allocate ... not owned by this node": the write failed. The same
# release landing a moment later -- after the read, before alloc_mutex
# -- answers -EAGAIN and the allocator chooses again
# (alloc_vs_bg_release.sh). Now both do (N-23).
#
# Staged as alloc_vs_bg_release.sh, with the writer held BEFORE its
# descriptor read (alloc_pause_before_geom_ms) while the release runs:
#   1. the write succeeds, and nothing logs a refusal;
#   2. the block is in a Block Group that is owned; fsck is clean.
#
# DISCRIMINATION: with the check answering -EPERM for a released group,
# the write fails (check 1).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/alloc_pause_before_geom_ms ] || { skip "alloc_pause_before_geom_ms is missing"; ct_exit; }

FREE_MARK=65535
MAP="$(ct_helper bg_map)"
EXTENT="$(ct_helper pending_poke)"
DEV="$(ct_dev 1700 abrr)"
MNT="$(ct_mnt abrr)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
compress_timing

bg_line() { "$MAP" "$DEV" | awk -v b="$1" '$1 == "bg" && $2 == b'; }
bg_field() { bg_line "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2}'; }
bg_of() {
    "$MAP" "$DEV" | awk -v l="$1" '$1 == "bg" {split($4,a,"="); if (a[2]+0 <= l+0 && a[2]+0 >= best) {best = a[2]+0; id = $2}} END {print id}'
}

nbg="$(ct_bgs_of_zg "$DEV" 0 | wc -l)"
[ "$nbg" -ge 3 ] || { fail "setup: only $nbg Block Groups in Zone Group 0"; ct_exit; }
ct_param_set bg_release_off 1
ct_param_set alloc_run_blocks 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# Fill Block Group 0 so the next allocation chooses an EMPTY group.
sync
umount "$MNT"
FREE0="$(bg_field 0 free | cut -d/ -f1)"
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/fill" bs=4096 count="$FREE0" conv=fsync status=none
sync
umount "$MNT"
FREE0="$(bg_field 0 free | cut -d/ -f1)"
[ "$FREE0" = 0 ] || { fail "setup: Block Group 0 still has $FREE0 free blocks"; ct_exit; }
released_before="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | wc -l)"
ct_mount "$DEV" "$MNT"

MARK="$(dmesg_mark)"
log "a writer chooses an empty Block Group and is held before its descriptor read while the release runs"
ct_param_set alloc_pause_before_geom_ms 4000
RC=0
dd if=/dev/urandom of="$MNT/victim" bs=4096 count=1 conv=fsync status=none 2>"$DEV.err" &
WPID=$!
ct_track file "$DEV.err"
sleep 0.5
ct_param_set bg_release_off 0
wait "$WPID" || RC=$?
ct_param_set bg_release_off 1
[ "$(cat /sys/module/cetrafs/parameters/alloc_pause_before_geom_ms)" = 0 ] ||
    fail "setup: the writer was never held"
ct_param_set alloc_pause_before_geom_ms 0
sync
REFUSED="$(dmesg_since "$MARK" | grep -c 'refusing to allocate from BG' || true)"
INO="$(stat -c %i "$MNT/victim")"
umount "$MNT"

released_after="$(ct_bgs_of_zg "$DEV" "$FREE_MARK" | wc -l)"
[ "$released_after" -gt "$released_before" ] ||
    { fail "setup: no Block Group was released during the pause -- the race was not arranged"; ct_exit; }
pass "setup: $((released_after - released_before)) Block Group(s) released while the writer was held"
[ "$RC" = 0 ] && [ "$REFUSED" = 0 ] && pass "1: the write chose again and succeeded" ||
    fail "1: write rc=$RC ($(cat "$DEV.err")), refusals logged: $REFUSED"
LBA="$("$EXTENT" "$DEV" extent "$INO" | cut -d' ' -f1)"
B="$(bg_of "$LBA")"
OWNER="$(bg_field "$B" owner_zg)"
[ -n "$LBA" ] && [ "$OWNER" != "$FREE_MARK" ] && pass "2: the block is in Block Group $B, owned by Zone Group $OWNER" ||
    fail "2: block ${LBA:-none} in Block Group ${B:-?} (owner_zg=${OWNER:-?})"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "2: fsck clean" || fail "2: fsck reports damage"
ct_exit
