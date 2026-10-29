#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# frees aimed at a foreign zone group are queued and drained exactly once
#
# A node may unlink a file whose blocks live in another node's ZG.
# Freeing them directly would race the owner's allocator on the same
# bitmap block, so the free is appended to the owning ZG's on-disk queue
# and applied by the owner. Applying is idempotent and happens BEFORE the
# entry is consumed, so a crash in between re-applies harmlessly rather
# than losing the free.
#
# The APPEND side is unreachable here -- with one node every ZG is owned
# locally and every free is correctly direct. Two-node ctest covers it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking the per-ZG pending-free queue drain"

# The append side (a node freeing into a FOREIGN ZG queues instead of
# touching the owner's bitmaps) can't run on this harness: a loop device
# has no cluster mutex, and on a no-mutex volume every free is correctly
# direct (the mount gate guarantees single-node there). What CAN be
# tested end to end is the drain side: plant queue entries on the raw
# image exactly as a peer's append would have left them, then confirm
# the owner applies them at mount -- bitmap bits cleared, BG/ZG free
# counters rolled up (fsck's cross-check), queue consumed, and a
# duplicate entry for the same blocks applied idempotently (no
# double-count).
PENDING_POKE="$(ct_helper pending_poke)"

PF_IMG="$(mktemp /tmp/cetrafs-pf-XXXXXX.img)"
truncate -s 560M "$PF_IMG"
PF_LOOPDEV="$(losetup --find --show "$PF_IMG")"
PF_MNT="$(mktemp -d /tmp/cetrafs-pf-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$PF_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$PF_LOOPDEV" "$PF_MNT"
require_cetrafs_mount "$PF_MNT"
PF_FREE_BEFORE="$(stat -f -c '%f' "$PF_MNT")"
dd if=/dev/zero of="$PF_MNT/pfprobe" bs=4096 count=2 conv=fsync status=none
PF_INO="$(stat -c '%i' "$PF_MNT/pfprobe")"
PF_FREE_USED="$(stat -f -c '%f' "$PF_MNT")"
[ "$((PF_FREE_BEFORE - PF_FREE_USED))" = "2" ] && pass "pending-free: probe file consumed exactly 2 blocks" ||
    fail "pending-free: probe consumed $((PF_FREE_BEFORE - PF_FREE_USED)) blocks, expected 2"
read -r PF_LBA PF_LEN <<< "$("$PENDING_POKE" "$PF_IMG" extent "$PF_INO" 2>/dev/null || true)"
# The probe's job was only to get a REAL extent allocated so we know a
# plausible {lba,count} to queue. Remove it now: a peer queueing a free
# has already unlinked the file on its side, so the faithful state here
# is "those blocks belong to nobody". Leaving the file in place would
# make the drain produce a volume where a live inode points at freed
# blocks -- genuinely corrupt, and fsck's content pass says so (which is
# how this was caught; the old structure-only fsck could not see it).
rm -f "$PF_MNT/pfprobe"
sync
umount "$PF_MNT"

read -r PF_LBA2 PF_LEN2 <<< "$PF_LBA $PF_LEN"
[ "$PF_LEN" = "2" ] || fail "pending-free: probe extent is $PF_LEN blocks, expected 2"

# Two identical entries for the same extent, whose bits the unlink above
# already cleared. Both must be consumed and both must apply as no-ops
# (no counter bump): duplicate queue entries are legal -- a tolerated
# double free produces them -- and the consume-first drain must pair each
# with its own slot rather than consuming one and re-applying the other
# on a later pass.
"$PENDING_POKE" "$PF_IMG" add 0 "$PF_LBA" "$PF_LEN" >/dev/null
"$PENDING_POKE" "$PF_IMG" add 0 "$PF_LBA" "$PF_LEN" >/dev/null

DMESG_MARK_PF="$(dmesg_mark)"
mount -t cetrafs "$PF_LOOPDEV" "$PF_MNT"
require_cetrafs_mount "$PF_MNT"
PF_LOG="$(dmesg_since "$DMESG_MARK_PF")"

if echo "$PF_LOG" | grep -q 'pending free: ZG 0 drained 2 entries'; then
    pass "pending-free: both queued entries were drained at mount"
else
    fail "pending-free: expected 'pending free: ZG 0 drained 2 entries', got: $(echo "$PF_LOG" | grep 'pending free:')"
fi

PF_FREE_AFTER="$(stat -f -c '%f' "$PF_MNT")"
[ "$PF_FREE_AFTER" = "$PF_FREE_BEFORE" ] &&
    pass "pending-free: free count unchanged -- neither queued entry double-counted" ||
    fail "pending-free: free count is $PF_FREE_AFTER, expected $PF_FREE_BEFORE (started $PF_FREE_BEFORE, used 2, queued-freed 2, duplicate must not double-count)"

# --- the queue now spans CAS REGIONS ------------------------------------
# Appending and draining are lock-free compare-and-swaps over one CAS
# region at a time (512 B = 32 slots), not the whole 4 KiB block, so a
# queue holding more than 32 entries is the case that actually walks
# region to region. Queue 40 distinct single-block extents from the
# probe file's own BG and confirm every one is applied exactly once.
umount "$PF_MNT"

PF_FREE_SPAN_BEFORE_MNT=""
PF_SPAN_N=40
PF_SPAN_BASE=$((PF_LBA + 64))
for i in $(seq 0 $((PF_SPAN_N - 1))); do
    "$PENDING_POKE" "$PF_IMG" add 0 $((PF_SPAN_BASE + i)) 1 >/dev/null
done
DMESG_MARK_PF2="$(dmesg_mark)"
mount -t cetrafs "$PF_LOOPDEV" "$PF_MNT"
require_cetrafs_mount "$PF_MNT"
PF_LOG2="$(dmesg_since "$DMESG_MARK_PF2")"
if echo "$PF_LOG2" | grep -q "pending free: ZG 0 drained $PF_SPAN_N entries"; then
    pass "pending-free: $PF_SPAN_N entries spanning multiple CAS regions all drained"
else
    fail "pending-free: expected 'drained $PF_SPAN_N entries', got: $(echo "$PF_LOG2" | grep 'pending free:')"
fi
umount "$PF_MNT"
PF_QDUMP2="$("$PENDING_POKE" "$PF_IMG" dump 0)"
[ -z "$PF_QDUMP2" ] && pass "pending-free: every region was consumed, none left behind" ||
    fail "pending-free: entries survived the multi-region drain: $PF_QDUMP2"
"$ROOT/userspace/fsck.cetra" "$PF_LOOPDEV" >/dev/null &&
    pass "pending-free: fsck clean after the multi-region drain" ||
    fail "pending-free: fsck failed after the multi-region drain"
mount -t cetrafs "$PF_LOOPDEV" "$PF_MNT"
require_cetrafs_mount "$PF_MNT"
umount "$PF_MNT"

PF_QDUMP="$("$PENDING_POKE" "$PF_IMG" dump 0)"
[ -z "$PF_QDUMP" ] && pass "pending-free: the queue was consumed (zeroed) after draining" ||
    fail "pending-free: queue still holds entries after drain: $PF_QDUMP"

"$ROOT/userspace/fsck.cetra" "$PF_LOOPDEV" >/dev/null &&
    pass "pending-free: fsck clean after drain (BG counters and ZG aggregate both rolled up)" ||
    fail "pending-free: fsck failed after drain"

rmdir "$PF_MNT"
losetup -d "$PF_LOOPDEV"
rm -f "$PF_IMG" "$PENDING_POKE"


ct_exit
