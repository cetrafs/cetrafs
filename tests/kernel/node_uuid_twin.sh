#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount never takes over a registry row another machine with the same identity is using
#
# A node finds its Node Registry row by its machine UUID, and a mount
# that found a REGISTERED row with its UUID re-attached to it at once:
# that is how a node gets its own row back after a crash. But the UUID
# comes from DMI, and DMI is not unique everywhere -- a cloned VM keeps
# its SMBIOS UUID unless the hypervisor regenerates it, firmware ships
# placeholder UUIDs, and the fallback hashes serial strings boards
# often leave generic. A second machine with the same identity took the
# LIVE first machine's row, and the two then ran as one node: the same
# Zone Groups, the same allocations, each renewing the row so neither
# ever looked stale.
#
# Now a row not left cleanly is watched before it is taken back: a
# crashed previous incarnation never beats again, a live twin does.
#
#  A. the row beats (a twin is mounted): the mount is refused, naming
#     cetrafs.node_uuid;
#  B. the row is a crash leftover that does not beat: re-attached;
#  C. the row was left cleanly: re-attached without waiting;
#  D. the twin is silent longer than two beats but less than the stale
#     window a peer waits: still refused (audit L1).
#
# DISCRIMINATION: proven 2026-11-05 with the watch removed from
# cetrafs_node_register() (cetrafs_node_row_quiet() not called): A mounts
# over the beating row, and B re-attaches without watching.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 uuidtwin)"
MNT="$(ct_mnt uuidtwin)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
grep -q '^state=1 .*last_seen=0 ' <<<"$("$NODE_POKE" "$DEV" 0)" && pass "row 0 is this machine's, left cleanly" ||
    { fail "setup: row 0 is not ours: $("$NODE_POKE" "$DEV" 0)"; ct_exit; }

log "A: a twin with this identity is mounted and beating"
"$NODE_POKE" "$DEV" 0 --beat >/dev/null
( for _ in $(seq 1 30); do "$NODE_POKE" "$DEV" 0 --beat >/dev/null 2>&1 || true; sleep 1; done ) &
TWIN=$!
MARK="$(dmesg_mark)"
rc=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
kill "$TWIN" 2>/dev/null || true
wait "$TWIN" 2>/dev/null || true
if [ "$rc" != 0 ] && grep -q "same node UUID" <<<"$(dmesg_since "$MARK")"; then
    pass "A: the mount was refused -- the row is a live twin's"
else
    [ "$rc" = 0 ] && umount "$MNT"
    fail "A: mount rc=$rc -- it took over a row another machine is heartbeating on"
fi

log "B: a crash leftover -- the same row, nobody beating it"
MARK="$(dmesg_mark)"
t0=$(date +%s)
if ct_mount "$DEV" "$MNT"; then
    pass "B: re-attached after $(($(date +%s) - t0)) s of watching"
    grep -q "watching it" <<<"$(dmesg_since "$MARK")" && pass "B: it watched the row first" ||
        fail "B: it re-attached without watching a row that was not left cleanly"
    ct_umount "$MNT"
else
    fail "B: a crashed previous incarnation's row was not taken back"
fi

log "C: left cleanly -- no wait"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q "watching it" <<<"$(dmesg_since "$MARK")" && fail "C: it waited on a row it had left cleanly" ||
    pass "C: re-attached at once"
ct_umount "$MNT"

log "D: a twin whose paths stall longer than two beats, inside the stale window"
# A peer calls a row dead only after the stale window; a live twin can
# be silent that long (queued multipath I/O) and still be live. The
# watch was two advertised beats + 5 s (7 s here) and re-attached over
# it (audit L1). Stale window 20 s; the twin beats once, at 12 s.
ct_param_set stale_secs 20
"$NODE_POKE" "$DEV" 0 --beat >/dev/null
( sleep 12; "$NODE_POKE" "$DEV" 0 --beat >/dev/null 2>&1 || true ) &
TWIN=$!
MARK="$(dmesg_mark)"
rc=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
wait "$TWIN" 2>/dev/null || true
if [ "$rc" != 0 ] && grep -q "same node UUID" <<<"$(dmesg_since "$MARK")"; then
    pass "D: the mount waited out the stale window and saw the stalled twin beat"
else
    [ "$rc" = 0 ] && umount "$MNT"
    fail "D: mount rc=$rc -- it took a row whose twin was silent less than the stale window"
fi

ct_exit
