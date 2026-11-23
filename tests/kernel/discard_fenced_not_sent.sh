#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a discard the fence stopped before it was sent is "not sent", not "may still land"
#
# A trim claims a run, makes the hold durable, and sends the discard.
# The send checks the fence first, twice, and on a fenced mount returns
# without sending anything -- but returned -EIO, which the caller can
# only read as "outcome unknown, may still execute". The run was then
# kept allocated and its hold synced, which fails on a fenced mount, so
# the mount was stopped with "could not make the hold ... durable -- a
# discard of it may still land" (a panic under errors=panic) about a
# discard that never left the host (N-38). The fence exits now answer
# a known "not sent".
#
# A FITRIM's discard is held just before it is sent
# (discard_issue_stall_ms) while this node's row is fenced (its
# fence_epoch bumped on the device); the heartbeat self-fences:
#   1. nothing says the discard may still land, and no hold sync fails;
#   2. the trim ends (fstrim returns).
#
# DISCRIMINATION: with the fence exits answering -EIO, the hold is
# synced on the fenced mount and that failure is logged (check 1).
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/discard_issue_stall_ms ] || { skip "discard_issue_stall_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
IMG="$(ct_big_image 1200 dfns)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfns)"
ct_track mnt "$MNT"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
P=/sys/module/cetrafs/parameters
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set discard_issue_stall_ms 0
compress_timing

ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ME="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
dd if=/dev/urandom of="$MNT/f" bs=1M count=16 conv=fsync status=none
rm -f "$MNT/f"
sync
ct_param_set discard_issue_stall_ms 6000
MARK="$(dmesg_mark)"
fstrim "$MNT" >/dev/null 2>&1 &
FPID=$!
wait_for 20 "dmesg_since '$MARK' | grep -q 'pausing .* before it is sent'" || true
dmesg_since "$MARK" | grep -q 'pausing .* before it is sent' ||
    { fail "setup: no discard was held"; ct_param_set discard_issue_stall_ms 0; wait "$FPID" || true; ct_exit; }
# A peer fences this node while its discard waits.
"$NPOKE" "$IMG" "$ME" --bump-fence 1 >/dev/null
wait_for 20 "dmesg_since '$MARK' | grep -q 'SELF-FENCED'" || true
dmesg_since "$MARK" | grep -q 'SELF-FENCED' && pass "setup: the node fenced itself while the discard was held" ||
    fail "setup: the node never fenced itself"
ct_param_set discard_issue_stall_ms 0
ENDED=0
for _ in $(seq 1 60); do kill -0 "$FPID" 2>/dev/null || { ENDED=1; break; }; sleep 0.5; done
wait "$FPID" 2>/dev/null || true
D="$(dmesg_since "$MARK")"
LAND="$(grep -c 'may still land' <<<"$D" || true)"
SYNCF="$(grep -c 'could not make the hold' <<<"$D" || true)"
log "after the fence: 'may still land' x$LAND, hold sync failures x$SYNCF"
[ "$LAND" = 0 ] && [ "$SYNCF" = 0 ] && pass "1: the discard reads as not sent: nothing kept, nothing synced on the fenced mount" ||
    fail "1: $(grep -m2 -E 'may still land|could not make the hold' <<<"$D" | tr '\n' ' ')"
[ "$ENDED" = 1 ] && pass "2: the trim ended" || fail "2: fstrim was still running 30 s after the fence"
umount "$MNT" 2>/dev/null || umount -l "$MNT"
ct_exit
