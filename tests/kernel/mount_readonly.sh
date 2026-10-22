#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# `mount -o ro` must actually BE read-only, and remount must not lie
#
# A read-only mount of a shared LUN is what an admin does to inspect a
# volume without perturbing the nodes that are live on it. cetrafs used
# to accept -o ro and then immediately write to it: it claimed a Zone
# Group (taking write capacity away from the live nodes), replayed its
# own journal into the data region, and started the defrag janitor,
# which relocates other people's file data in the background. The VFS
# blocked user writes, so from the outside it looked read-only.
#
# What a read-only mount IS allowed to write is its own Node Registry
# row -- it registers and heartbeats so peers see it as alive and honour
# the read-presence bits it publishes, which is what stops a peer
# unlinking a file it is reading. Everything else is skipped.
#
# The second half: .reconfigure was NULL, so `mount -o remount,ro` just
# flipped the flag with the filesystem never finding out -- a mount that
# had already claimed ZGs and started the janitor, now calling itself
# read-only. Both directions are refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
ZG_POKE="$(ct_helper zg_poke)"
JOURNAL_POKE="$(ct_helper journal_poke)"

# ------------------------------------------------ a ro mount takes nothing
log "a read-only mount must not claim a Zone Group"
IMG="$(ct_image 560 ro)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ro)"
ct_mkfs_small "$DEV" >/dev/null

PRISTINE="$("$ZG_POKE" "$DEV" 0)"
case "$PRISTINE" in
*"owner_node_id=65535"*) : ;;
*) fail "setup: a freshly mkfs'd ZG 0 should be unowned, got: $PRISTINE" ;;
esac

# Compressed BEFORE the mount: cetrafs_heartbeat_start() queues the
# first tick with whatever the interval is at mount time.
compress_timing

mount -t cetrafs -o ro "$DEV" "$MNT"
ct_track mnt "$MNT"
require_cetrafs_mount "$MNT"
pass "a read-only mount is accepted"

ZG_AFTER="$("$ZG_POKE" "$DEV" 0)"
case "$ZG_AFTER" in
*"owner_node_id=65535"*) pass "ro mount: ZG 0 is still unowned (nothing was claimed)" ;;
*) fail "ro mount: ZG 0 was claimed by a read-only mount: $ZG_AFTER" ;;
esac

INFO="/proc/fs/cetrafs/$(basename "$DEV")/info"
if grep -q '^write_ready: no' "$INFO"; then
    pass "ro mount: procfs reports write_ready: no (owns no allocation capacity)"
else
    fail "ro mount: expected 'write_ready: no', got: $(grep '^write_ready' "$INFO")"
fi

# Registration and the heartbeat are deliberately KEPT: without them
# peers would see this node as dead and ignore (then clear) the read-
# presence bits that stop them unlinking what it is reading.
ROW="$("$NODE_POKE" "$DEV" 0)"
case "$ROW" in
*"state=1"*) pass "ro mount: this node did register a Node Registry row (an observer, not a ghost)" ;;
*) fail "ro mount: expected the row to be REGISTERED, got: $ROW" ;;
esac

SEQ1="$("$NODE_POKE" "$DEV" 0 | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p')"
sleep $((TEST_HB_SECS * 3 + 1))
SEQ2="$("$NODE_POKE" "$DEV" 0 | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p')"
if [ "$SEQ2" -gt "$SEQ1" ]; then
    pass "ro mount: the heartbeat still renews our own row ($SEQ1 -> $SEQ2)"
else
    fail "ro mount: hb_seq did not advance ($SEQ1 -> $SEQ2) -- peers would declare this observer dead"
fi

if touch "$MNT/nope" 2>/dev/null; then
    fail "ro mount: a write succeeded on a read-only mount"
else
    pass "ro mount: writes are refused (EROFS)"
fi

# ---------------------------------------------------- remount transitions
log "remount must not silently flip a mode the filesystem cannot change"
if mount -o remount,rw "$MNT" 2>/dev/null; then
    fail "remount ro -> rw was accepted: this mount claimed no ZG and has no janitor, it cannot serve writes"
else
    pass "remount ro -> rw is refused"
fi
# Still read-only after the refusal.
grep -q " $MNT cetrafs ro," /proc/self/mounts &&
    pass "remount ro -> rw left the mount read-only" ||
    fail "remount ro -> rw was refused but the mount is no longer ro: $(grep " $MNT " /proc/self/mounts)"

umount "$MNT"

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
if mount -o remount,ro "$MNT" 2>/dev/null; then
    fail "remount rw -> ro was accepted: this mount still owns ZGs and still runs the defrag janitor"
    # Put it back. On a build without the fix the flag really does flip,
    # and the unguarded write a few lines below would then abort the
    # suite -- leaving every later section with no FAIL line at all,
    # which reads exactly like it was never meant to run.
    mount -o remount,rw "$MNT" 2>/dev/null || true
else
    pass "remount rw -> ro is refused"
fi
# A remount that changes nothing must still work -- the refusal is for
# the rdonly transition specifically, not for remount as such.
if mount -o remount "$MNT" 2>/dev/null; then
    pass "a no-op remount still succeeds"
else
    fail "a no-op remount was refused"
fi

# cetrafs parses no options of its own, so the VFS rejects anything it is
# handed. Asserted so it stays true if a .parse_param is ever added.
if mount -t cetrafs -o bogusopt=1 "$DEV" "$(ct_mnt bogus)" 2>/dev/null; then
    fail "an unknown mount option was accepted"
else
    pass "an unknown mount option is refused"
fi

# ------------------------------------------------------ reads still work
log "a read-only mount still reads"
{ echo "contents that must survive a read-only remount" >"$MNT/payload" && mkdir "$MNT/adir"; } ||
    fail "setup: could not populate the volume before remounting it read-only"
sync
umount "$MNT"

mount -t cetrafs -o ro "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
READ_BACK="$(cat "$MNT/payload")"
[ "$READ_BACK" = "contents that must survive a read-only remount" ] &&
    pass "ro mount: file contents read back correctly" ||
    fail "ro mount: read back '$READ_BACK'"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"
[ "$LS" = "adir payload " ] && pass "ro mount: readdir works" || fail "ro mount: ls shows '$LS'"
umount "$MNT"

# ------------------------------------------- a ro mount does not replay
#
# Replay WRITES -- into whichever data region the entry names. The
# recipe is journal.sh's: log a real entry, wipe the target block to
# simulate "the real write never landed", then mount. A read-write mount
# repairs it; a read-only mount must leave it exactly as it found it.
log "a read-only mount must not replay the journal"
JIMG="$(ct_image 560 rojournal)"
JDEV="$(ct_loop "$JIMG")"
JMNT="$(ct_mnt rojournal)"
ct_mkfs "$JDEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

mount -t cetrafs "$JDEV" "$JMNT"
ct_track mnt "$JMNT"
JMARK="$(dmesg_mark)"
touch "$JMNT/newfile"
TARGET_LBA="$(dmesg_since "$JMARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
[ -n "$TARGET_LBA" ] || fail "setup: no journal entry was logged by creating a file"
BACKUP="$(ct_tmp rojbackup)"
dd if="$JDEV" of="$BACKUP" bs=4096 skip="$TARGET_LBA" count=1 status=none
umount "$JMNT"
dd if=/dev/zero of="$JDEV" bs=4096 seek="$TARGET_LBA" count=1 conv=notrunc status=none
"$JOURNAL_POKE" "$JDEV" 0 0 "$TARGET_LBA" "$BACKUP" >/dev/null
ZEROED="$(dd if="$JDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"

RMARK="$(dmesg_mark)"
mount -t cetrafs -o ro "$JDEV" "$JMNT"
RO_REPLAY_LOG="$(dmesg_since "$RMARK" | grep 'journal replay:' || true)"
umount "$JMNT"
AFTER_RO="$(dd if="$JDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"

[ -z "$RO_REPLAY_LOG" ] &&
    pass "ro mount: no journal replay ran" ||
    fail "ro mount: replay ran on a read-only mount: $RO_REPLAY_LOG"
[ "$AFTER_RO" = "$ZEROED" ] &&
    pass "ro mount: the target block is byte-for-byte as the read-only mount found it" ||
    fail "ro mount: the target block changed under a read-only mount"

# The control that gives the two assertions above their meaning: the
# same image, the same outstanding entry, mounted read-WRITE, really is
# repaired. Without it "nothing happened" could just mean the entry was
# never valid.
WMARK="$(dmesg_mark)"
mount -t cetrafs "$JDEV" "$JMNT"
W_REPLAY_LOG="$(dmesg_since "$WMARK" | grep 'journal replay:' || true)"
umount "$JMNT"
AFTER_RW="$(dd if="$JDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"
echo "$W_REPLAY_LOG" | grep -q 'replayed 1 valid entry' &&
    pass "control: the same entry IS replayed by a read-write mount" ||
    fail "control: a read-write mount did not replay the entry: $W_REPLAY_LOG"
[ "$AFTER_RW" != "$ZEROED" ] &&
    pass "control: the read-write mount restored the target block" ||
    fail "control: the target block is still zeroed after a read-write mount"

reset_stale_window
ct_exit
