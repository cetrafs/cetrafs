#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a volume being repaired offline must not be mountable
#
# `fsck -r` and growfs both refuse to touch a volume a node has mounted.
# That covers one direction only. Nothing stopped a node MOUNTING
# halfway through a repair, because the repairer claimed nothing on the
# device for a mount to see -- and a repair pass is minutes of blind
# full-block writes to the inode table, the bitmaps and the dirent
# blocks, while a kernel allocates out of the same structures.
#
# Registering as an ordinary node would not help: on a CAW device
# several mounters are the normal case and a peer would simply join. So
# the tools hold a registry row in CETRAFS_NODE_STATE_REPAIR, which
# fill_super() refuses to mount past.
#
# It is a LEASE, not a flag, and that half matters just as much: a
# repairer that is killed must not leave the volume unmountable
# forever. Both halves are asserted below.
#
# Discrimination: remove the check from fill_super() and the mount with
# a live claim in place succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 repairclaim)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt repairclaim)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

# 1. It mounts before any of this, or nothing below means anything.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
pass "control: the volume mounts normally"
ct_umount "$MNT"

# 2. A live repair claim: state 2, refreshed just now.
"$NPOKE" "$IMG" 0 2 aa "$(date +%s)" >/dev/null 2>&1 ||
    fail "could not write a repair claim into registry row 0"
blockdev --flushbufs "$DEV" 2>/dev/null || true

RC=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || RC=$?
if [ "$RC" = 0 ]; then
    umount "$MNT" 2>/dev/null || true
    fail "the volume mounted while a repair claim was live -- a node and fsck -r would be writing it at once"
else
    pass "a mount is refused while the repair claim is live (exit $RC)"
    dmesg | tail -5 | grep -q "being repaired" &&
        pass "and the refusal says why" ||
        pass "refused, though the kernel message was not in the last few lines"
fi

# 3. The lease side: a claim nobody is refreshing must stop blocking.
"$NPOKE" "$IMG" 0 2 aa "$(( $(date +%s) - 3600 ))" >/dev/null 2>&1 ||
    fail "could not backdate the repair claim"
blockdev --flushbufs "$DEV" 2>/dev/null || true

ct_mount "$DEV" "$MNT" &&
    pass "a stale claim (its repairer died) no longer blocks the mount" ||
    fail "a repair claim nobody refreshes blocks the volume forever"
ct_umount "$MNT"

# 4. The tools refuse each other through the same claim.
"$NPOKE" "$IMG" 0 2 aa "$(date +%s)" >/dev/null 2>&1
blockdev --flushbufs "$DEV" 2>/dev/null || true
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "already being repaired" &&
    pass "fsck -r refuses a volume another repairer holds" ||
    fail "fsck -r ran against a volume with a live repair claim: $(echo "$OUT" | head -1)"

# 5. And a repair that finishes leaves nothing behind -- a claim nobody
# clears costs the operator the staleness window on every mount.
"$NPOKE" "$IMG" 0 0 00 0 >/dev/null 2>&1
blockdev --flushbufs "$DEV" 2>/dev/null || true
"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true
blockdev --flushbufs "$DEV" 2>/dev/null || true
STATE="$("$NPOKE" "$IMG" 0 2>&1 | sed -n 's/.*state=\([0-9]*\).*/\1/p' | head -1)"
[ "$STATE" = "0" ] &&
    pass "fsck -r released its claim when it finished" ||
    fail "fsck -r left registry row 0 in state $STATE"

ct_mount "$DEV" "$MNT" && pass "and the volume mounts again" || fail "the volume no longer mounts"
ct_umount "$MNT"

# 6. A registry with no free row must not make a volume unrepairable.
#
# Rows are not released when a node unmounts -- a clean departure just
# zeroes last_seen -- so a cluster that has been reinstalled a few times
# has every row spoken for. Refusing to repair there would be a trap of
# its own, so a departed row is BORROWED and put back. The node it
# belongs to re-attaches by UUID, and nothing can mount while the claim
# is live anyway.
ROWS="$("$(ct_helper sb_poke)" "$IMG" | sed -n 's/^node_table_count[^0-9]*\([0-9]*\).*/\1/p' | head -1)"
[ -n "$ROWS" ] && [ "$ROWS" -ge 2 ] || fail "could not read node_table_count"

for r in $(seq 0 $((ROWS - 1))); do
    "$NPOKE" "$IMG" "$r" 1 "b$r" 0 >/dev/null 2>&1 || true   # REGISTERED, departed
done
blockdev --flushbufs "$DEV" 2>/dev/null || true
BEFORE_ROWS="$(dd if="$IMG" bs=4096 skip="$(( $("$(ct_helper sb_poke)" "$IMG" | sed -n 's/^node_table_start[^0-9]*\([0-9]*\).*/\1/p' | head -1) ))" count="$ROWS" 2>/dev/null | md5sum)"

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "claimed registry row" &&
    pass "fsck -r borrows a departed row when none is free" ||
    fail "fsck -r could not claim anything on a full registry: $(echo "$OUT" | grep -i registry | head -1)"

blockdev --flushbufs "$DEV" 2>/dev/null || true
AFTER_ROWS="$(dd if="$IMG" bs=4096 skip="$(( $("$(ct_helper sb_poke)" "$IMG" | sed -n 's/^node_table_start[^0-9]*\([0-9]*\).*/\1/p' | head -1) ))" count="$ROWS" 2>/dev/null | md5sum)"
[ "$AFTER_ROWS" = "$BEFORE_ROWS" ] &&
    pass "and puts the registration back, byte for byte" ||
    fail "the borrowed registration was not restored -- a node would lose its row"

ct_exit
