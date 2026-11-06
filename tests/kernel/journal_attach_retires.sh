#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# attach retires journal entries left under a clean flag, so no later replay applies them
#
# A node wedged by a storage outage can have a journal entry write queued
# past its fence. A peer judges it stale, replays its area and parks the
# flag CLEAN; then the entry lands. Attach and replay skip the slot scan
# on a CLEAN area, so the entry waited: the node remounts, journals
# something (the flag goes DIRTY), crashes -- and the next replay finds
# the old entry, whose guard still matches because its target write was
# refused by the fence. The operation had returned -EIO; replay made it
# happen anyway (audit 2026-11-06 M10). Attach now retires every live
# entry in its own area once the replay the flag asked for is done.
#
# Staged: a valid, guard-matching entry for a file's data block planted
# in this node's own area with the flag parked CLEAN. Mount (attach),
# journal a create, stop the mount (shutdown=now: nothing more is
# written, the flag stays DIRTY), unmount, mount again: that attach
# replays. The data block must not hold the planted payload.
#
# DISCRIMINATION: with attach leaving leftovers (journal_keep_leftovers),
# the second mount's replay writes the payload into the file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_keep_leftovers ] || { skip "journal_keep_leftovers is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
EPOKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 jretire)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jretire)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
dd if=/dev/urandom of="$MNT/f" bs=4096 count=2 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
TARGET="$("$EPOKE" "$IMG" extent "$INO" | cut -d' ' -f1)"
[ -n "$TARGET" ] && [ "$TARGET" -gt 0 ] || { fail "setup: no data block for f ($TARGET)"; ct_exit; }
blk() { dd if="$IMG" bs=4096 skip="$TARGET" count=1 status=none | sha256sum | cut -d' ' -f1; }
ORIG="$(blk)"
PAY="$(ct_tmp jretire-pay)"
head -c 4096 /dev/urandom >"$PAY"
WANT="$(sha256sum <"$PAY" | cut -d' ' -f1)"

"$JPOKE" "$IMG" "$NID" 3 "$TARGET" "$PAY" >/dev/null           # guard matches the block as it is now
"$JPOKE" "$IMG" "$NID" --claim release >/dev/null               # ...and the flag parked CLEAN over it
"$JPOKE" "$IMG" "$NID" --dump | grep -q "state=0 " ||
    { fail "setup: the flag is not CLEAN: $("$JPOKE" "$IMG" "$NID" --dump)"; ct_exit; }

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(blk)" = "$ORIG" ] || { fail "setup: the first attach already changed the block"; ct_umount "$MNT"; ct_exit; }
touch "$MNT/after" # journaled: the flag goes DIRTY
sync -f "$MNT"
echo shutdown=now >"$(ct_procdir "$DEV")/controls"
umount "$MNT" 2>/dev/null || umount -l "$MNT"
"$JPOKE" "$IMG" "$NID" --dump | grep -q "state=1 " ||
    { fail "setup: the stopped mount did not leave the flag DIRTY: $("$JPOKE" "$IMG" "$NID" --dump)"; ct_exit; }

ct_mount "$DEV" "$MNT" # this attach replays the area
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
case "$(blk)" in
"$WANT") fail "a leftover entry under a clean flag was applied by a later replay" ;;
"$ORIG") pass "the leftover entry was retired: a later replay left the block alone" ;;
*) fail "the block changed to neither its own content nor the payload" ;;
esac
dmesg_since "$MARK" | grep -q "retired 1 entry left in this node's area under a clean flag" &&
    pass "the first attach reported what it retired" || fail "the first attach did not report retiring the leftover"
ct_exit
