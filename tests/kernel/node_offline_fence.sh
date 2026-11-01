#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# leaving must not undo a peer's fence
#
# At unmount a node records its departure by clearing last_seen in its
# own Node Registry row. That was a read / modify / BLIND WRITE of the
# whole row -- and the row is the one thing a peer writes to when it
# decides this node is dead: fence_epoch, the lease that tells a node
# to stop writing.
#
# So a peer revoking our lease in the window between that read and that
# write had its bump written back out of existence. The code carried a
# comment claiming the opposite ("a concurrent fence_epoch bump is
# carried through rather than reverted") -- the whole row goes back from
# a copy taken before the bump, so the bump is exactly what is lost.
# CLAUDE.md rule 7: the comment named its own hazard and got the
# direction backwards.
#
# It is one compare-and-swap of the row's own sector now, like every
# other change to that row.
#
# node_offline_delay_ms holds the window open. In production it is
# microseconds wide, which is why the blind write survived review.
#
# Discrimination: restore the blind write and the epoch below comes back
# at its pre-bump value.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 offfence)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt offfence)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

epoch_of() { "$NPOKE" "$IMG" 0 2>&1 | sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' | head -1; }

BEFORE="$(epoch_of)"
[ -n "$BEFORE" ] || fail "could not read fence_epoch from row 0"

ct_param_set node_offline_delay_ms 2500

# Unmount in the background; it will sit inside the window.
( umount "$MNT" ) &
UPID=$!
sleep 0.8

# A peer revoking our lease, right there.
"$NPOKE" "$IMG" 0 --bump-fence 1 >/dev/null 2>&1 ||
    fail "could not bump the fence epoch -- the setup did not arrange the situation"
BUMPED="$(epoch_of)"
[ "$BUMPED" -gt "$BEFORE" ] ||
    fail "the bump did not take ($BEFORE -> $BUMPED), so there is nothing to lose"

wait "$UPID" 2>/dev/null || true
ct_param_set node_offline_delay_ms 0
blockdev --flushbufs "$DEV" 2>/dev/null || true

AFTER="$(epoch_of)"
echo "fence_epoch: $BEFORE before, $BUMPED after the peer's bump, $AFTER after the unmount"

[ "$AFTER" = "$BUMPED" ] &&
    pass "the departure left the peer's fence epoch standing" ||
    fail "the unmount reverted the fence epoch ($BUMPED -> $AFTER) -- the peer's revocation is gone"

DEPARTED="$("$NPOKE" "$IMG" 0 2>&1 | sed -n 's/.*last_seen=\([0-9]*\).*/\1/p' | head -1)"
[ "$DEPARTED" = "0" ] &&
    pass "and still recorded the departure (last_seen cleared)" ||
    fail "the departure was not recorded: last_seen=$DEPARTED"

ct_exit
