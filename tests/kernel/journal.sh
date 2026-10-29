#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the per-node journal: write, replay after a crash, and no replay when consumed
#
# Journals are per NODE, not per ZG: single writer by construction, and
# every entry is consumed immediately after its target lands, so a
# surviving entry always means its writer crashed mid-operation.
#
# It does NOT follow that redo is safe on its own -- that argument
# ("nobody else can have modified the target since") assumed a lock the
# nofilelock mode does not take, and cost a corrupted VM image. What
# makes redo safe is the prev_checksum verification in replay; this
# suite covers the write/replay/consume machinery, and
# journal_replay_guard.sh covers the verification.
#
# Covers our own crash replayed at mount, a consumed entry NOT replayed,
# a stale peer's area replayed before its ZG is stolen, and an entry
# whose target is out of bounds being refused rather than applied.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JOURNAL_POKE="$(ct_helper journal_poke)"
ZG_POKE="$(ct_helper zg_poke)"

log "checking the per-NODE journal write path and replay (per-node journal)"
# Independent throwaway image, same pattern as the LOCK_*/GATE_* blocks
# above -- but needs a real nonzero -J, unlike every other mkfs call in
# the other suites (which deliberately pass -J 0 to stay fast). That's also
# exactly what makes the rest of this suite passing unchanged with
# -J 0 throughout meaningful: it proves the journal write path is a
# true no-op when nothing is reserved for it, not just untested.
# -J is per-NODE now; -M 4 keeps the node count (and so the total
# reservation) small enough for this little image.
JOURNAL_IMG="$(mktemp /tmp/cetrafs-journal-XXXXXX.img)"
truncate -s 560M "$JOURNAL_IMG"
JOURNAL_LOOPDEV="$(losetup --find --show "$JOURNAL_IMG")"
JOURNAL_MNT="$(mktemp -d /tmp/cetrafs-journal-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$JOURNAL_LOOPDEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT"
require_cetrafs_mount "$JOURNAL_MNT"

DMESG_MARK_J="$(dmesg_mark)"
touch "$JOURNAL_MNT/newfile"
J_LOG="$(dmesg_since "$DMESG_MARK_J")"

# Creating a file adds a dirent to root's existing (mkfs-written) data
# block, which dir.c journals (into THIS node's own area -- this is the
# first-ever mount, so it registered row 0) before the real in-place
# write -- see journal.c's fs_debug line.
TARGET_LBA="$(echo "$J_LOG" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
if [ -n "$TARGET_LBA" ]; then
    pass "journal: creating a file logged a journal entry (target_lba=$TARGET_LBA)"
else
    fail "journal: no 'journal: txn ...' line found in dmesg after creating a file"
fi

[ -e "$JOURNAL_MNT/newfile" ] && pass "journal: file visible before any corruption" ||
    fail "journal: file missing before any corruption"

# Save the target block's correct content before touching anything --
# needed below as the payload for a freshly-constructed journal entry.
JOURNAL_BACKUP="$(mktemp /tmp/cetrafs-journal-backup-XXXXXX)"
dd if="$JOURNAL_LOOPDEV" of="$JOURNAL_BACKUP" bs=4096 skip="$TARGET_LBA" count=1 status=none

# Simulate "crashed between the journal commit and the real write
# landing" by wiping the target block directly on the raw device, then
# constructing a fresh, valid journal entry for it in node 0's area via
# journal_poke -- see that file's header comment for why a real entry
# can't be left dangling by ordinary operations (the kernel consumes
# each entry within its own operation now). Unmounting first, same
# reasoning as every other poke in these suites.
umount "$JOURNAL_MNT"
dd if=/dev/zero of="$JOURNAL_LOOPDEV" bs=4096 seek="$TARGET_LBA" count=1 conv=notrunc status=none
"$JOURNAL_POKE" "$JOURNAL_LOOPDEV" 0 0 "$TARGET_LBA" "$JOURNAL_BACKUP" >/dev/null

DMESG_MARK_REPLAY="$(dmesg_mark)"
mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT"
require_cetrafs_mount "$JOURNAL_MNT"
REPLAY_LOG="$(dmesg_since "$DMESG_MARK_REPLAY")"

if echo "$REPLAY_LOG" | grep -q 'journal replay: node 0 replayed 1 valid entry'; then
    pass "replay: this node's own mount-time replay found and applied the one entry"
else
    fail "replay: expected 'journal replay: node 0 replayed 1 valid entry', got: $(echo "$REPLAY_LOG" | grep 'journal replay:')"
fi

LS_OUT="$(ls -a "$JOURNAL_MNT" | sort)"
EXPECTED="$(printf '.\n..\nnewfile\n' | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "replay: root directory's data block (fully zeroed before remount) was restored exactly" ||
    fail "replay: ls after replay shows unexpected entries: $LS_OUT"

# A replayed entry is consumed (its header invalidated) so it isn't
# redundantly replayed forever -- confirm a further remount with
# nothing new to replay does no replay work at all, and the repaired
# state still holds on its own.
umount "$JOURNAL_MNT"
DMESG_MARK_REPLAY2="$(dmesg_mark)"
mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT"
require_cetrafs_mount "$JOURNAL_MNT"
REPLAY_LOG2="$(dmesg_since "$DMESG_MARK_REPLAY2")"

if echo "$REPLAY_LOG2" | grep -q 'journal replay:'; then
    fail "replay: expected no replay activity on a remount with nothing left to replay, got: $(echo "$REPLAY_LOG2" | grep 'journal replay:')"
else
    pass "replay: an already-consumed entry is not redundantly replayed again"
fi

LS_OUT="$(ls -a "$JOURNAL_MNT" | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "replay: file still present and correct after a clean remount" ||
    fail "replay: ls after a clean remount shows unexpected entries: $LS_OUT"

# A journal entry names the block it repairs. Nothing in the format
# stops a corrupted (or maliciously poked) header from naming a block
# OUTSIDE every BG data region -- and replay applies payloads blindly by
# design, since redo has to be idempotent. Pointed at block 0 that is
# the superblock: replay would overwrite it with a dirent payload and
# destroy the volume, at mount, before anything could object.
#
# The bounds check in journal.c exists for exactly this. Removing it
# makes both assertions below fail (the volume stops mounting at all).
umount "$JOURNAL_MNT"
DMESG_MARK_OOB="$(dmesg_mark)"
SB_BEFORE="$(dd if="$JOURNAL_LOOPDEV" bs=4096 count=1 2>/dev/null | md5sum)"
"$JOURNAL_POKE" "$JOURNAL_IMG" 0 0 0 "$JOURNAL_BACKUP" >/dev/null

# The mount is deliberately guarded. Without the bounds check this does
# not merely assert wrong -- replay lands a dirent payload on block 0 and
# the volume stops mounting entirely, which under set -e would abort the
# run with no FAIL line and no summary at all. That is the third of the
# three "a test that cannot fail" modes this suite has already been
# bitten by; a negative control that aborts the harness is not reporting.
OOB_MOUNTED=no
if mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT" 2>/dev/null; then
    OOB_MOUNTED=yes
    pass "replay: the volume still mounts after the out-of-range entry"
else
    fail "replay: the volume no longer mounts -- replay destroyed the superblock"
fi
OOB_LOG="$(dmesg_since "$DMESG_MARK_OOB")"

echo "$OOB_LOG" | grep -q "outside every BG data region" &&
    pass "replay: an entry naming a block outside every BG data region is refused" ||
    fail "replay: an out-of-range journal target was not refused: $(echo "$OOB_LOG" | grep -i journal)"

SB_AFTER="$(dd if="$JOURNAL_LOOPDEV" bs=4096 count=1 2>/dev/null | md5sum)"
[ "$SB_BEFORE" = "$SB_AFTER" ] &&
    pass "replay: the superblock was not overwritten by the refused entry" ||
    fail "replay: the superblock CHANGED -- replay wrote a payload over it"

if [ "$OOB_MOUNTED" = yes ]; then
    LS_OUT="$(ls -a "$JOURNAL_MNT" | sort)"
    [ "$LS_OUT" = "$EXPECTED" ] && pass "replay: the volume is intact after refusing the entry" ||
        fail "replay: directory damaged after the out-of-range entry: $LS_OUT"
else
    # Keep the rest of the suite runnable on a destroyed volume.
    "$ROOT/userspace/mkfs.cetra" "$JOURNAL_LOOPDEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT"
    require_cetrafs_mount "$JOURNAL_MNT"
fi

# Stale-node replay at reclaim time: simulate "node 1
# crashed mid-operation while owning ZG 0" -- a stale REGISTERED row, a
# dangling entry in NODE 1's journal area whose target write never
# landed, and ZG 0 poked to node 1's ownership. This node's next mount
# must replay node 1's journal (repairing the target) BEFORE stealing
# ZG 0 from it, not after and not never.
umount "$JOURNAL_MNT"
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$JOURNAL_LOOPDEV" 1 aa
"$ZG_POKE" "$JOURNAL_LOOPDEV" 0 1 >/dev/null
dd if=/dev/zero of="$JOURNAL_LOOPDEV" bs=4096 seek="$TARGET_LBA" count=1 conv=notrunc status=none
"$JOURNAL_POKE" "$JOURNAL_LOOPDEV" 1 0 "$TARGET_LBA" "$JOURNAL_BACKUP" >/dev/null

DMESG_MARK_STALEJ="$(dmesg_mark)"
mount -t cetrafs "$JOURNAL_LOOPDEV" "$JOURNAL_MNT"
require_cetrafs_mount "$JOURNAL_MNT"
# The steal (and the replay that must precede it) happens on a tick once
# node 1's heartbeat has demonstrably stopped, not at mount -- see the ZG
# reclaim section for why first sight cannot judge a peer.
wait_out_stale_window
sleep $((TEST_HB_SECS * 2))
STALEJ_LOG="$(dmesg_since "$DMESG_MARK_STALEJ")"

if echo "$STALEJ_LOG" | grep -q 'journal replay: node 1 replayed 1 valid entry'; then
    pass "stale replay: the dead peer's journal was replayed at reclaim time"
else
    fail "stale replay: expected 'journal replay: node 1 replayed 1 valid entry', got: $(echo "$STALEJ_LOG" | grep 'journal replay:')"
fi
if echo "$STALEJ_LOG" | grep -q 'reclaiming ZG 0 from stale node 1'; then
    pass "stale replay: ZG 0 was then reclaimed from the stale owner"
else
    fail "stale replay: expected ZG 0 to be reclaimed from stale node 1"
fi
LS_OUT="$(ls -a "$JOURNAL_MNT" | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "stale replay: the dead peer's unfinished write was repaired before the steal" ||
    fail "stale replay: ls shows unexpected entries after stale-node replay: $LS_OUT"
reset_stale_window

umount "$JOURNAL_MNT"
rmdir "$JOURNAL_MNT"
losetup -d "$JOURNAL_LOOPDEV"
rm -f "$JOURNAL_IMG" "$JOURNAL_BACKUP"


ct_exit
