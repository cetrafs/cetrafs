#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs makes the old volume unmountable first, and checks for users after
#
# mkfs wrote the superblock LAST, so for its whole run -- and for good
# after an interrupted mkfs -f -- the old superblock stayed valid over
# half-zeroed tables, and a mount found nothing wrong. Its probe for a
# live node ran before the first write, and it ignored repair claims,
# so it formatted a volume a live fsck -r or growfs was working on.
#
# Now block 0 is zeroed first and the registry is probed after; anyone
# found gets the superblock back. A mount that read the old superblock
# before the zero and registers after it re-reads block 0 once its row
# is committed, and refuses.
#
#   A: a node heartbeating in the registry -- while mkfs watches it,
#      block 0 is already zero; mkfs refuses and puts the superblock back.
#   B: a live repair claim -- mkfs refuses and puts the superblock back.
#   C: a mount stalled before registering while block 0 is rewritten
#      under it must refuse.
#
# DISCRIMINATION: with the old order, block 0 still holds a valid
# superblock during A's watch, and B formats the volume. Without the
# kernel's post-registration re-read, C mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# mkfs watches each row for the kernel's stale window (120 s), several
# times here; the test knob gives two beats (35 s), still inside the
# beater's 45 s.
export CETRAFS_PEER_PROBE_SECS=4
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 mkfsretire)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mkfsretire)"
ct_track mnt "$MNT"
MKFS() { "$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f; }
b0() { dd if="$IMG" bs=4096 count=1 status=none | sha256sum | cut -d' ' -f1; }
ZERO="$(head -c 4096 /dev/zero | sha256sum | cut -d' ' -f1)"
# Beats off a saved superblock, as a mounted node does off the one it read.
beat() { ( for _ in $(seq 1 90); do NODE_POKE_SB="$IMG.sb" "$NPOKE" "$IMG" "$1" --beat >/dev/null 2>&1 || true; sleep 0.5; done ) & BEATER=$!; }
stop_beat() { kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true; }

# A different -N from MKFS's: mkfs is deterministic, so a reformat with
# the same arguments writes the identical superblock and "the old one
# is back" could not fail.
fresh() {
    ct_mkfs_small "$DEV" -N 2048 >/dev/null
    blockdev --flushbufs "$DEV"
    OLD="$(b0)"
    dd if="$IMG" of="$IMG.sb" bs=4096 count=1 status=none
}
ct_track file "$IMG.sb"

# --- A: a live node
fresh
"$NPOKE" "$IMG" 1 1 bb "$(date +%s)" >/dev/null
beat 1
OUTF="$IMG.out"; ct_track file "$OUTF"
(MKFS >"$OUTF" 2>&1; echo "rc=$?" >>"$OUTF") &
MPID=$!
for _ in $(seq 1 40); do grep -q 'watching' "$OUTF" && break; sleep 0.25; done
grep -q 'watching' "$OUTF" || { fail "A: setup: mkfs never started watching the live node: $(head -2 "$OUTF")"; }
MID="$(b0)"
wait "$MPID" || true
stop_beat
[ "$MID" = "$ZERO" ] && pass "A: while mkfs watched for live nodes, block 0 was already zero" ||
    fail "A: block 0 still held the old superblock while mkfs watched -- a mount then sees a valid volume"
grep -q 'mounted by another node' "$OUTF" && pass "A: mkfs refused the live node" ||
    fail "A: mkfs did not refuse: $(tail -2 "$OUTF")"
[ "$(b0)" = "$OLD" ] && pass "A: and put the old superblock back, byte for byte" ||
    fail "A: the old superblock was not restored"

# --- B: a live repair claim
fresh
"$NPOKE" "$IMG" 0 2 aa "$(date +%s)" >/dev/null
beat 0
OUT="$(MKFS 2>&1)" && RC=0 || RC=$?
stop_beat
[ "$RC" != 0 ] && grep -q 'being repaired' <<<"$OUT" && pass "B: mkfs refused a volume under a live repair" ||
    fail "B: mkfs ran over a live repair claim (rc=$RC): $(tail -1 <<<"$OUT")"
blockdev --flushbufs "$DEV"
[ "$(b0)" = "$OLD" ] && pass "B: and the old superblock is back" || fail "B: block 0 is not the old superblock"

# --- C: a mount in flight while block 0 is rewritten
fresh
ct_param_set mount_register_stall_ms 3000
MARK="$(dmesg_mark)"
(rc=0; mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?; echo "$rc" >"$IMG.rc") &
MPID=$!; ct_track file "$IMG.rc"
sleep 1
dd if=/dev/zero of="$IMG" bs=4096 count=1 conv=notrunc,fsync status=none
wait "$MPID" || true
RC="$(cat "$IMG.rc")"
if [ "$RC" = 0 ]; then
    ct_umount "$MNT"
    fail "C: the mount came up although block 0 was zeroed while it was in flight"
else
    dmesg_since "$MARK" | grep -q 'superblock was rewritten' &&
        pass "C: the mount refused: the superblock changed under it" ||
        fail "C: the mount failed (exit $RC) but not on the superblock re-check: $(dmesg_since "$MARK" | grep -i refus | tail -1)"
fi
dd if="$IMG.sb" of="$IMG" bs=4096 count=1 conv=notrunc,fsync status=none
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT" && { pass "control: the restored volume mounts"; require_cetrafs_mount "$MNT"; ct_umount "$MNT"; } || fail "control: no mount"
ct_exit
