#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a blocking flock(LOCK_EX) takes the lock of a holder that died, and never of one that is alive
#
# Under nofilelock the whole-file lock exists only on request: the
# migration orchestrator opens the image and flock(LOCK_EX)s it. An open
# steps past (and clears) a stale holder's lock -- but a holder that
# died AFTER the fd was opened left flock polling -ETXTBSY for ever: the
# lock is never released, and stale reclaim lived only in the open path.
# flock now does what open does: fence the dead holder, replay its
# journal, and displace exactly its claim.
#
# DISCRIMINATION (measured on the unfixed code): the blocking flock
# times out against the dead holder.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 flockstale)"
MNT="$(ct_mnt flockstale)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo image >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
sync
dump() { "$LOCK_POKE" "$DEV" "$INO"; }

log "a LIVE holder keeps its lock"
exec 9>>"$MNT/vm.img" # opened while unlocked
"$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null # node 1 takes it after our open
( for _ in $(seq 1 40); do "$NODE_POKE" "$DEV" 1 --beat >/dev/null 2>&1; sleep 0.25; done ) &
BEATER=$!
if flock -x -w 6 9; then
    fail "flock took the lock of a holder that is still beating"
    flock -u 9 || true
else
    pass "flock waited on a live holder and did not take its lock"
fi
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
dump | grep -q 'owner=1 mode=1' && pass "the live holder still holds it ($(dump))" ||
    fail "the live holder's lock changed: $(dump)"

log "the holder dies: a waiting flock takes it over"
MARK="$(dmesg_mark)"
if flock -x -w 20 9; then
    pass "flock acquired the dead holder's lock"
else
    fail "flock timed out on a holder that stopped beating -- nothing reclaims it"
fi
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
dump | grep -q "owner=${NID:-0} mode=1" && pass "the lock is now this node's ($(dump))" ||
    fail "the lock is not ours: $(dump)"
dmesg_since "$MARK" | grep -q 'reclaiming a stale lock from node 1' && pass "the reclaim is logged" ||
    fail "no reclaim logged"
flock -u 9
exec 9>&-

"$NODE_POKE" "$DEV" 1 0 bb 0 >/dev/null
ct_umount "$MNT"
ct_exit
