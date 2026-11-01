#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# evict must re-check the record it judged, immediately before freeing it
#
# evict_inode already reads the record forced-fresh and refuses on a
# generation mismatch or a nonzero nlink. That check is real, and it is
# not ADJACENT to the act: between it and the bitmap CAS that frees the
# number sits the foreign-opener check, itself another forced-fresh
# read. The verdict is therefore at least one device round trip old by
# the time it is acted on.
#
# The background scrub lost exactly that race with 378 microseconds to
# play with: a create reused the number between the verdict read and the
# free, two files ended up sharing one inode, and fsck saw nothing. The
# cure there was cetrafs_free_inode_if_dead() -- re-read immediately
# before the CAS and require the record to still be the dead one that
# was judged, same nlink and same generation. Evict now uses the same
# primitive instead of a second copy of the argument.
#
# evict_stall_before_free_ms widens the gap so something can be driven
# into it. In production it is microseconds; the guard is not about how
# narrow it is, it is about it not being closed.
#
# Discrimination: put plain cetrafs_free_inode() back and the number is
# freed despite the record having changed -- the first assertion fails,
# and free_inodes climbs by one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 evictadj)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt evictadj)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
free_inodes() { sed -n 's/^free_inodes: //p' "$PROC"; }

echo hello > "$MNT/doomed"
INO="$(stat -c '%i' "$MNT/doomed")"
sync
BEFORE="$(free_inodes)"
log "ino=$INO, free_inodes=$BEFORE"

MARK="$(dmesg_mark)"
ct_param_set evict_stall_before_free_ms 4000

# Unlink and drop the last reference: evict fires and parks in the gap.
( rm -f "$MNT/doomed" ) &
RM_PID=$!
sleep 1

# Drive the thing the guard exists for into the gap: the number is
# reborn as a different file, which stamps a new generation. Poked on
# the device, which is what a PEER's create would have produced.
"$POKE" "$IMG" bumpgen "$INO" 999 >/dev/null
"$POKE" "$IMG" nlink "$INO" 1 >/dev/null
wait "$RM_PID" || true
ct_param_set evict_stall_before_free_ms 0
sleep 1

AFTER="$(free_inodes)"
log "free_inodes after: $AFTER"

[ "$AFTER" = "$BEFORE" ] &&
    pass "the number was NOT freed after the record changed under the verdict ($AFTER)" ||
    fail "free_inodes went $BEFORE -> $AFTER: the number was handed back although the record is no longer the one evict judged"

dmesg_since "$MARK" | grep -qiE "changed under the verdict|reborn|ESTALE" &&
    pass "and the refusal says so" ||
    log "note: no refusal logged (the free may have been declined earlier)"

# A refused free is a bounded, diagnosable leak -- the trade this
# filesystem makes everywhere: better an inode fsck can name than a
# number handed to two files.
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 &&
    log "note: fsck clean" ||
    pass "fsck names the deliberately-leaked inode rather than finding it shared"

ct_exit
