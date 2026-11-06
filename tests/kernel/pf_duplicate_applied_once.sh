#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free queued twice is applied once: the second copy cannot free a block reallocated in between
#
# The pending-free drain consumes a batch of queue entries and then
# applies each under its own alloc_mutex hold. A free queued twice (a
# tolerated double free leaves exactly that) was applied twice, and an
# allocation landing between the two applies got its block freed by the
# second: a live file's block reading FREE, handed to the next writer
# (audit 2026-11-06 L19).
#
# Staged on a live mount: a one-block file is written and removed, so
# its block L is free and is the next one the allocator hands out. Two
# entries for L are planted in ZG 0's queue. A writer then triggers an
# on-demand drain, which pf_apply_stall_ms holds between its applies;
# a second writer allocates in that window and gets L. When the drain
# resumes, L must stay that writer's, and the first writer must get a
# different block.
#
# DISCRIMINATION: applying every consumed entry, the second copy frees
# L under the second writer and the first writer is handed L as well --
# two files share one block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pf_apply_stall_ms ] || { skip "pf_apply_stall_ms is missing"; ct_exit; }
PP="$(ct_helper pending_poke)"

IMG="$(ct_image 560 pfdup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfdup)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }

dd if=/dev/urandom of="$MNT/f1" bs=4096 count=1 conv=fsync status=none
sync
L="$(ext "$MNT/f1")"
[ -n "$L" ] || { fail "setup: no extent for f1"; ct_exit; }
rm -f "$MNT/f1"
sync
"$PP" "$IMG" add 0 "$L" 1 >/dev/null
"$PP" "$IMG" add 0 "$L" 1 >/dev/null
log "block $L freed and queued twice"

MARK="$(dmesg_mark)"
ct_param_set pf_drain_min_ms 0
ct_param_set pf_apply_stall_ms 4000
dd if=/dev/urandom of="$MNT/g" bs=4096 count=1 conv=fsync status=none &
GPID=$!
sleep 1
ct_param_set pf_drain_min_ms 600000 # the second writer must not drain itself
dd if=/dev/urandom of="$MNT/f2" bs=4096 count=1 conv=fsync status=none
wait "$GPID"
ct_param_set pf_apply_stall_ms 0
sync
F2="$(ext "$MNT/f2")"
G="$(ext "$MNT/g")"
log "f2 at $F2, g at $G"
[ "$F2" = "$L" ] || { fail "setup: the second writer got block $F2, not the freed block $L"; ct_umount "$MNT"; ct_exit; }
pass "setup: the second writer allocated the queued block $L inside the drain"
[ "$G" != "$L" ] && pass "the first writer got another block ($G): the duplicate did not free $L again" ||
    fail "the first writer was handed $L too -- the duplicate entry freed the second writer's block"
dmesg_since "$MARK" | grep -q "queued lba=$L count=1 twice" && pass "and the duplicate was reported" ||
    fail "the duplicate entry was not reported"
[ -z "$("$PP" "$IMG" dump 0)" ] && pass "both entries were consumed" || fail "entries left: $("$PP" "$IMG" dump 0)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
