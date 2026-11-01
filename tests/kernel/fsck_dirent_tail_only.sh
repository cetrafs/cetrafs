#!/usr/bin/env bash
# damage confined to the dirent tail must not cost a directory its names
#
# A dirent block's tail CRC covers the whole block, so a mismatch says
# "something in here changed" and nothing about what. The repair for an
# unreadable block erases it and lets /lost+found take the contents by
# inode number -- right when the entries are rubble, and a total loss of
# every name in the directory when the damage was only the tail: a torn
# write of the tail itself, a stamp that never landed, a flipped bit in
# the CRC.
#
# fsck now tests the entries first. If every slot still parses -- and,
# on a first block, '.' and '..' are both there and '.' points at the
# directory itself -- the block is coherent, the tail is re-stamped and
# the entries are counted normally. Anything less and the old rebuild
# stands, because salvaging SOME entries out of a damaged block means
# choosing between two disagreeing copies of the truth.
#
# Kernel-tier because it needs a directory with real NAMES in it: the
# root of a fresh image holds only '.' and '..', which the rebuild path
# writes back byte for byte -- so the two repairs are indistinguishable
# there and the first version of this suite passed against both. Only
# the four CRC bytes are touched, which is what makes this "the tail
# and nothing else".
#
# Discrimination: make fsck_dirent_block_coherent() return 0 and the
# names below are gone -- the block comes back with '.' and '..' only.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 direnttail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt direnttail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
for n in alpha bravo charlie delta echo foxtrot; do echo "$n" > "$MNT/d/$n"; done
sync
DIR_INO="$(stat -c %i "$MNT/d")"
NAMES_BEFORE="$(ls "$MNT/d" | sort | tr '\n' ' ')"
ct_umount "$MNT"

[ "$NAMES_BEFORE" = "alpha bravo charlie delta echo foxtrot " ] ||
    fail "the directory does not hold the six names this is about: '$NAMES_BEFORE'"

ct_fsck "$DEV" >/dev/null || fail "the volume is already reported corrupt"

PHYS="$("$IPOKE" "$IMG" extents "$DIR_INO" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
[ -n "$PHYS" ] && [ "$PHYS" != "0" ] || fail "could not locate the directory's dirent block"

# Capture the entry table so "the names survived" is a claim about
# bytes that were really there.
BEFORE="$(dd if="$IMG" bs=4096 skip="$PHYS" count=1 2>/dev/null | head -c 4088 | md5sum)"
[ -n "$BEFORE" ] || fail "could not read root's dirent block"

# Break ONLY the CRC: four bytes at the tail's second field. The entry
# table is left exactly as it was, which is the whole point.
CRC_OFF=$(( PHYS * 4096 + 4096 - 4 ))
printf '\xde\xad\xbe\xef' | dd of="$IMG" bs=1 seek="$CRC_OFF" count=4 conv=notrunc status=none
blockdev --flushbufs "$DEV" 2>/dev/null || true

OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
echo "$OUT" | grep -qE "dirent-tail CRC|tail checksum invalid" &&
    pass "fsck reports the broken tail" ||
    fail "fsck did not notice the broken tail: $(echo "$OUT" | grep -E '^ERR' | head -2 | tr '\n' ' ')"

REP="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
echo "$REP" | grep -qE "re-stamped the dirent tail|rebuilt the root" &&
    pass "fsck -r repaired it" ||
    fail "fsck -r did nothing: $(echo "$REP" | grep -E '^ERR|rebuilt|re-stamped' | head -3 | tr '\n' ' ')"

blockdev --flushbufs "$DEV" 2>/dev/null || true
AFTER="$(dd if="$IMG" bs=4096 skip="$PHYS" count=1 2>/dev/null | head -c 4088 | md5sum)"

[ "$AFTER" = "$BEFORE" ] &&
    pass "the entry table came through byte for byte -- no name was lost" ||
    fail "the repair rewrote the entries: a tail-only fault erased the directory's names"

ct_fsck "$DEV" >/dev/null &&
    pass "and the volume is clean again" ||
    fail "fsck still reports problems after the repair"

# And the names are back where they belong, not in /lost+found.
ct_mount "$DEV" "$MNT"
NAMES_AFTER="$(ls "$MNT/d" 2>/dev/null | sort | tr '\n' ' ')"
ct_umount "$MNT"
[ "$NAMES_AFTER" = "$NAMES_BEFORE" ] &&
    pass "the directory still lists: $NAMES_AFTER" ||
    fail "the directory now lists '$NAMES_AFTER' instead of '$NAMES_BEFORE'"

ct_exit
