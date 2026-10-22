#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# .lookup must not hand out a file the namespace no longer has
#
# A directory entry is the only thing standing between a name and an
# inode record, and lookup trusted it completely. Three ways that goes
# wrong, all of them states this filesystem already knows it can reach:
#
#   nlink = 0   cetrafs_unlink_locked() persists nlink = 0 and leaves
#               the record otherwise intact; cetrafs_free_inode() then
#               clears only the bitmap bit. A dirent still naming such
#               an inode -- the "dangling entry" fsck reports, and what
#               a stale cached dirent block produces across nodes --
#               instantiated the DEAD file: its mode, its size, and its
#               extents, pointing at blocks that are back in the
#               allocator and may already belong to another file.
#
#   out of range / corrupt record -- a dirent is 10 bytes of inode
#               number with no checksum of its own beyond the block
#               tail, so an out-of-range or unreadable target has to
#               fail cleanly rather than read whatever block the
#               arithmetic lands on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"
CORRUPT="$(ct_helper corrupt_poke)"

IMG="$(ct_image 560 lookup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lookup)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PAYLOAD="secret data that must not survive deletion"
echo "$PAYLOAD" >"$MNT/victim"
echo "bystander" >"$MNT/other"
VICTIM_INO="$(stat -c '%i' "$MNT/victim")"
ct_umount "$MNT"

log "a dirent naming a deleted record must not resolve"
"$POKE" "$IMG" nlink "$VICTIM_INO" 0 >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
# The name is still listed -- this is the point: readdir reads dirents,
# and the dirent is intact. Only resolving it can tell.
ls "$MNT" | grep -q '^victim$' && pass "the dangling entry is still listed by readdir" ||
    fail "setup: the entry is gone, so lookup is not being tested"

if OUT="$(cat "$MNT/victim" 2>&1)"; then
    fail "lookup resolved a deleted record and returned its contents: '$OUT'"
else
    pass "lookup refuses a dirent whose record says nlink=0 ($(echo "$OUT" | sed 's/.*: //'))"
fi
if stat "$MNT/victim" >/dev/null 2>&1; then
    fail "stat resolved a deleted record"
else
    pass "stat refuses it too (the refusal is in iget, not in one caller)"
fi
# Unrelated names in the same directory keep working: the refusal is
# per-inode, not a directory-wide failure.
[ "$(cat "$MNT/other")" = "bystander" ] &&
    pass "an unrelated entry in the same directory still resolves" ||
    fail "the refusal broke the whole directory"
ct_umount "$MNT"

log "control: the same entry resolves again once the record is live"
"$POKE" "$IMG" nlink "$VICTIM_INO" 1 >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
[ "$(cat "$MNT/victim")" = "$PAYLOAD" ] &&
    pass "control: with nlink=1 the very same entry reads correctly" ||
    fail "control: the entry does not resolve even with nlink restored -- the refusal above proved nothing"
ct_umount "$MNT"

log "a dirent naming an impossible inode fails cleanly"
"$CORRUPT" "$IMG" repoint 1 victim 999999 >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
if OUT="$(cat "$MNT/victim" 2>&1)"; then
    fail "lookup resolved an inode number past the end of the inode table: '$OUT'"
else
    pass "lookup refuses an out-of-range inode number ($(echo "$OUT" | sed 's/.*: //'))"
fi
ct_umount "$MNT"

log "a dirent naming an unreadable record fails cleanly"
"$CORRUPT" "$IMG" repoint 1 victim "$VICTIM_INO" >/dev/null 2>&1
"$POKE" "$IMG" corrupt "$VICTIM_INO" >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
if OUT="$(cat "$MNT/victim" 2>&1)"; then
    fail "lookup resolved a record whose checksum does not match: '$OUT'"
else
    pass "lookup refuses a record that fails its checksum ($(echo "$OUT" | sed 's/.*: //'))"
fi
ct_umount "$MNT"

log "ordinary lookup semantics"
IMG2="$(ct_image 560 lookup2)"
DEV2="$(ct_loop "$IMG2")"
MNT2="$(ct_mnt lookup2)"
ct_mkfs_small "$DEV2" >/dev/null
ct_mount "$DEV2" "$MNT2"
: >"$MNT2/present"
[ -e "$MNT2/present" ] && pass "an existing name resolves" || fail "an existing name does not resolve"
[ -e "$MNT2/absent" ] && fail "a name that was never created resolves" ||
    pass "a name that does not exist gives ENOENT"
# NAME_MAX and CETRAFS_FILENAME_MAX are both 255, so this is really
# the VFS refusing before lookup is reached. Asserted as a statement of
# the invariant: if CETRAFS_FILENAME_MAX ever shrinks below NAME_MAX,
# lookup's own check becomes the one that matters.
LONG="$(printf 'x%.0s' $(seq 1 300))"
if touch "$MNT2/$LONG" 2>/dev/null; then
    fail "a 300-character name was accepted"
else
    pass "an over-long name is refused with ENAMETOOLONG"
fi
# Past the first dirent block: lookup must scan the whole directory, not
# just the block the name would be in if directories never grew.
mkdir "$MNT2/big"
for i in $(seq 1 120); do : >"$MNT2/big/f$i"; done
[ -e "$MNT2/big/f120" ] && pass "a name in a grown directory's later block resolves" ||
    fail "lookup stops at the first dirent block"
ct_umount "$MNT2"
ct_fsck "$DEV2" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV2" 2>&1 | tail -2)"

ct_exit
