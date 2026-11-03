#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free-count recount does not lose a free that lands while it runs
#
# cetrafs_bg_reconcile_free_count() recounts a Block Group's free blocks
# from its bitmap, writes that count, and resets the BG's epoch -- which
# DROPS every delta accrued in memory, since the recount already includes
# their effects. That held only for deltas accrued BEFORE the recount: a
# free (or allocation) landing between the recount and the reset is in
# neither, and the count stayed off by it until fsck. The recount ran
# without alloc_mutex, the lock every bitmap change and its delta take.
#
# Driven with alloc_force_enospc_once (a write takes the recount-on-ENOSPC
# path) and reconcile_pause_ms (held after its recount); a file in the
# same Block Group is deleted in that window.
#
# DISCRIMINATION: without the lock fsck finds the BG's cached count below
# its bitmap by the deleted file's blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in reconcile_pause_ms alloc_force_enospc_once; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
EXTENT_POKE="$(ct_helper pending_poke)"
MAP="$(ct_helper bg_map)"

IMG="$(ct_image 560 recfree)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt recfree)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0

dd if=/dev/urandom of="$MNT/victim" bs=4096 count=32 status=none
sync
VPHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c %i "$MNT/victim")" | cut -d' ' -f1)"
bg_of() { "$MAP" "$IMG" | awk -v l="$1" '$1 == "bg" { split($4, a, "="); if (a[2] <= l) b = $2 } END { print b }'; }
VBG="$(bg_of "$VPHYS")"

ct_param_set reconcile_pause_ms 4000
ct_param_set alloc_force_enospc_once 1
MARK="$(dmesg_mark)"
(dd if=/dev/urandom of="$MNT/w" bs=4096 count=1 conv=fsync status=none 2>/dev/null) &
W=$!
wait_for 10 "dmesg_since '$MARK' | grep -q 'reconcile: BG [0-9]* recounted, pausing'" ||
    { fail "setup: no recount was held"; ct_param_set reconcile_pause_ms 0; ct_param_set alloc_force_enospc_once 0; ct_exit; }
RBG="$(dmesg_since "$MARK" | grep -oP 'reconcile: BG \K[0-9]+' | head -1)"
[ "$RBG" = "$VBG" ] && pass "setup: the recount of BG $RBG is held, and victim's blocks are in it" ||
    { fail "setup: the recount is of BG $RBG but victim is in BG $VBG"; ct_exit; }
rm "$MNT/victim" # frees 32 blocks of BG $RBG in the window
sync
wait "$W" || true
ct_param_set reconcile_pause_ms 0
ct_param_set alloc_force_enospc_once 0
ct_umount "$MNT"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "ERR: BG$RBG cached free_data_blocks" <<<"$OUT" &&
    fail "the free that landed during the recount was lost: $(grep "ERR: BG$RBG" <<<"$OUT" | head -1)" ||
    pass "BG $RBG's cached count matches its bitmap"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -2)" || pass "fsck clean"
ct_exit
