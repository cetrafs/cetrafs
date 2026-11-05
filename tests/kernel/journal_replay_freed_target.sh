#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# journal replay does not redo onto a block that has been freed since
#
# Replay applies an entry when its target still holds the image the
# entry was written against (prev_checksum). Freeing a block changes no
# byte of it, so a target freed since -- its directory removed, its
# leaf dropped -- still matched, and replay wrote a dead node's image
# onto a block the allocator may be handing to someone else (audit L9).
# Nothing published can refer to a freed block (a reference is never
# durable before its bit), so there is nothing there to repair: replay
# now checks the bitmap first and skips it.
#
# Staged: a directory's dirent block, journaled while the directory had
# an entry; the directory is then emptied and removed, freeing the block
# with its bytes in place; an entry carrying the earlier image, guarded
# against the block as it now reads, is planted in this node's area.
#
# DISCRIMINATION: proven by removing the bitmap check from replay: the
# freed block is rewritten with the entry's payload.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_image 560 jrft)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrft)"
ct_track mnt "$MNT"
PAYLOAD="$(ct_tmp jrft-payload)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/d"
sync
MARK="$(dmesg_mark)"
touch "$MNT/d/f1"
TARGET="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
ct_umount "$MNT"
[ -n "$TARGET" ] || { fail "setup: no journal entry for a create in d"; ct_exit; }
dd if="$DEV" of="$PAYLOAD" bs=4096 skip="$TARGET" count=1 status=none

ct_mount "$DEV" "$MNT"
rm "$MNT/d/f1"
rmdir "$MNT/d"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "^ERR" <<<"$OUT" && { fail "setup: the volume is not clean before the plant: $(grep -m2 ERR <<<"$OUT")"; ct_exit; }
BEFORE="$(dd if="$DEV" bs=4096 skip="$TARGET" count=1 status=none | md5sum | cut -d' ' -f1)"
[ "$BEFORE" != "$(md5sum <"$PAYLOAD" | cut -d' ' -f1)" ] || { fail "setup: the freed block already holds the payload"; ct_exit; }

"$JPOKE" "$DEV" "$NID" 0 "$TARGET" "$PAYLOAD" --guard-current >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
ct_umount "$MNT"
AFTER="$(dd if="$DEV" bs=4096 skip="$TARGET" count=1 status=none | md5sum | cut -d' ' -f1)"
log "freed block $TARGET: before $BEFORE, after $AFTER; $(dmesg_since "$MARK" | grep -m1 'freed since' || true)"
[ "$AFTER" = "$BEFORE" ] && pass "replay left the freed block alone" ||
    fail "replay rewrote block $TARGET, freed since its entry was written"
dmesg_since "$MARK" | grep -q "target block $TARGET has been freed since" &&
    pass "and said why it skipped the entry" || fail "no skip message for the freed target"
grep -q "^state=0 " <<<"$("$JPOKE" "$DEV" "$NID" --dump)" && pass "the entry was consumed (area CLEAN)" ||
    fail "the area is still dirty"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
