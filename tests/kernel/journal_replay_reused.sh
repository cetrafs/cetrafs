#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay does not redo an entry over a block that has since been freed and reused as file data
#
# Replay judges a guarded entry's target: the after-image means the
# write landed, the before-image means it never did, a complete block
# that is neither means a peer rewrote it (refused). A block that fails
# its own tail checksum was taken for a TEAR and redone -- the case the
# journal exists for.
#
# But a file data block has no tail at all, so it "fails its tail
# checksum" too. A dead node's entry for an extent leaf or dirent block
# that a peer has since freed (a truncate or punch under nofilelock,
# with nothing replaying first) and reused for another file's data was
# judged TORN, and the stale-node sweep wrote the dead node's metadata
# image over that file's data. Silent: fsck has no checksum on data.
#
# A guarded entry is only written for a block read and modified in
# place, so a real tear still carries the entry's tail MAGIC (whichever
# sector, old or new, the tail holds). Anything else is refused.
# journal_replay_live_writer.sh keeps the other side covered: a genuine
# tear is still repaired.
#
# Played single-node with journal_poke, as journal_replay_guard.sh does:
# an entry carrying a dirent image, targeted at a block of a regular
# file, replayed at mount.
#
# DISCRIMINATION: journal_ignore_kind restores the old judgement, and the
# file's block is then overwritten.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_ignore_kind ] || { skip "journal_ignore_kind is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 jreused)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jreused)"
PD="$(basename "$DEV")"
DIRENT="$(ct_tmp jreused-dirent)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ctr() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
DLBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
dd if=/dev/urandom of="$MNT/g" bs=4096 count=1 status=none
sync
GPHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c %i "$MNT/g")" | cut -d' ' -f1)"
SUM="$(md5sum <"$MNT/g")"
ct_umount "$MNT"
[ -n "$DLBA" ] && [ -n "$GPHYS" ] && [ "$GPHYS" != "$DLBA" ] &&
    pass "setup: a dirent block ($DLBA) and a data block of g ($GPHYS)" ||
    { fail "setup: dirent lba '$DLBA', g's block '$GPHYS'"; ct_exit; }
dd if="$DEV" of="$DIRENT" bs=4096 skip="$DLBA" count=1 status=none

# replay_once <ignore_kind>: plant the entry, mount (replays our own
# area), report g's checksum and the refused-counter delta
replay_once() {
    ct_param_set journal_ignore_kind "$1"
    "$JPOKE" "$DEV" 0 0 "$GPHYS" "$DIRENT" --guard-stale >/dev/null
    MARK="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT"
    GOT="$(md5sum <"$MNT/g")"
    ct_umount "$MNT"
    ct_param_set journal_ignore_kind 0
}

log "1: an entry whose target is now another file's data"
replay_once 0
dmesg_since "$MARK" | grep -q "target block $GPHYS is no longer a block of the entry's kind" &&
    pass "1: replay recognised the reused block and refused the entry" ||
    fail "1: no refusal logged: $(dmesg_since "$MARK" | grep 'journal replay' | tail -2)"
[ "$GOT" = "$SUM" ] && pass "1: g's data is intact" || fail "1: g's data was overwritten by the dead node's dirent image"

log "negative control: judged as before, the same entry overwrites g"
replay_once 1
[ "$GOT" != "$SUM" ] && pass "control: with journal_ignore_kind the redo overwrote g -- the check above is what saved it" ||
    fail "control: g survived even without the check -- the case above proves nothing"
ct_exit
