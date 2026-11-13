#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# msync(MS_SYNC) against a concurrent write(2) to the same page
#
# Writer A stores a generation into word 0 of a shared mapping and calls
# msync(MS_SYNC) after each store; writer B pwrite(2)s a counter into word 1
# of the same page. Both run at once (msync_vs_write run). Every msync must
# succeed, both writers must finish every iteration, and after a remount both
# words must hold the values the writers last produced: a msync that returns
# before its store reaches the device, or a write(2) that a later page
# write-back puts back over, is a lost word here.
#
# Model check, no negative control. Neither writer's store can be broken by
# a test knob without inventing a failure: no knob drops a msync'd store or
# reverts a write(2) to a stale page, so a pass shows the orderings hold on
# this rig, not that the oracle would catch their absence. Durability by a
# remount is also weaker than a crash (a clean unmount flushes everything),
# which is why the crash rig (tests/crash/) owns the cut-point half of this.
# ct-timeout: 240
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

MVW="$(ct_helper msync_vs_write)"
IMG="$(ct_image 560 msyncvw)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt msyncvw)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

ITERS=3000
OUT="$(timeout 200 "$MVW" run "$MNT/mvw" "$ITERS" 2>&1)" && RC=0 || RC=$?
log "run: $OUT (rc=$RC)"
if [ "$RC" != 0 ]; then
    fail "a msync failed or a writer died mid-run ($OUT, rc=$RC)"
elif [ "$(sed -n 's/^lastA=\([0-9]*\) .*/\1/p' <<<"$OUT")" != "$ITERS" ] || [ "$(sed -n 's/.* lastB=\([0-9]*\)$/\1/p' <<<"$OUT")" != "$ITERS" ]; then
    fail "setup: a writer did not finish its $ITERS iterations ($OUT)"
else
    pass "every msync returned 0 and both writers finished $ITERS iterations ($OUT)"
fi
LA="$(sed -n 's/^lastA=\([0-9]*\) .*/\1/p' <<<"$OUT")"
LB="$(sed -n 's/.* lastB=\([0-9]*\)$/\1/p' <<<"$OUT")"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CHK="$("$MVW" check "$MNT/mvw" "$LA" "$LB" 2>&1)" && CRC=0 || CRC=$?
log "after remount: $CHK (rc=$CRC)"
if [ "$CRC" = 0 ]; then
    pass "after a remount both words hold the last values written ($CHK)"
else
    fail "a word was lost across the remount: $CHK"
fi

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qE '^ERR' <<<"$OUT"; then fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"; else pass "fsck clean"; fi
ct_exit
