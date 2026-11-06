#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a nofilelock write-open refuses a peer's exclusive lock that lands before its presence swap
#
# Under nofilelock a write-open claims no lock but honours one: a peer's
# flock(LOCK_EX) makes the file unopenable here. The open checks for that
# lock, then publishes its presence bit with a swap -- and the swap
# re-asked the question only for a READ-open. A peer's lock claim landing
# between the check and the swap, and finding no presence bit yet, left
# one node holding the file exclusive while another had it open for write
# (audit 2026-11-06 M7). The swap now refuses a foreign exclusive lock for
# a writer too -- but not a peer's suspended-writer mark, which under
# nofilelock is a live migration handing the file to exactly this open.
#
# Staged: open_presence_stall_ms holds a write-open between its checks and
# its swap; the peer's state is planted in the record meanwhile.
#
# DISCRIMINATION: with the writer's swap not re-asking, the open beside
# the planted lock succeeds. The suspended case is the other half: a fix
# that also refused suspended writers would break the handoff.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/open_presence_stall_ms ] || { skip "open_presence_stall_ms is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 nflflock)"
MNT="$(ct_mnt nflflock)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo data >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
RES="$(ct_tmp nflflock-res)"

# open_with_planted <poke args...>: a write-open held at its swap while
# the peer's state is planted; prints "opened" or "refused".
open_with_planted() {
    rm -f "$RES"
    ct_param_set open_presence_stall_ms 2500
    (if exec 3>>"$MNT/f"; then echo opened >"$RES"; sleep 1; else echo refused >"$RES"; fi) 2>/dev/null &
    local p=$!
    sleep 1
    "$LOCK_POKE" "$DEV" "$INO" "$@" >/dev/null
    wait "$p" || true
    ct_param_set open_presence_stall_ms 0
    cat "$RES" 2>/dev/null || echo none
}

R="$(open_with_planted 1 1)" # node 1 takes the exclusive lock
"$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null
"$LOCK_POKE" "$DEV" "$INO" --unreader 0 >/dev/null 2>&1 || true
case "$R" in
refused) pass "a write-open refused a peer's exclusive lock that landed before its presence swap" ;;
opened) fail "a write-open went ahead beside a peer's exclusive lock (one node exclusive, another writing)" ;;
*) fail "setup: the held open reported nothing ($R)" ;;
esac

R="$(open_with_planted --suspended 1)" # node 1 is a migration source handing over
"$LOCK_POKE" "$DEV" "$INO" --unreader 1 >/dev/null
case "$R" in
opened) pass "a write-open beside a peer's suspended writer (a handoff) still opens" ;;
refused) fail "a write-open was refused by a peer's suspended writer -- the migration handoff is broken" ;;
*) fail "setup: the held open reported nothing ($R)" ;;
esac
ct_umount "$MNT"
ct_exit
