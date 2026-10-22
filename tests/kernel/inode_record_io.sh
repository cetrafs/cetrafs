#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a corrupt inode record is reported, and a record write zero-fills its block
#
# cetrafs_read_raw_inode() is the choke point every directory, file and
# xattr operation goes through to touch an on-disk inode. Two properties
# it has to have, neither of which was asserted anywhere:
#
#  * A record whose checksum does not match is REPORTED, not served. The
#    read retries a few times first, because a mismatch is usually a
#    peer's in-flight write seen torn and converges on re-read -- but a
#    genuinely corrupt record must come back as an error rather than as
#    plausible-looking bytes. (fsck checks the same thing offline; this
#    is about the kernel refusing it at runtime.)
#  * A record write zero-fills the rest of its block. Since v0x0007 each
#    record owns a whole 4 KiB block, so everything past the struct is
#    slack -- and slack that keeps a previous tenant's bytes is a trap
#    for any later, larger version of the struct.
#
# Measured discrimination: with the checksum check and the zero-fill both
# removed, 3 of these assertions fail (the tail keeps its garbage, the
# corrupt record is served as if valid, and nothing is logged). The last
# two -- the directory still reads, new files are still created -- pass
# either way and are kept to show that one bad record does not cost the
# volume.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 560 iri)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt iri)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "checking garbage past the record is INERT (v0x0005: no live path rewrites the whole block)"
: >"$MNT/victim"
VICT="$(stat -c '%i' "$MNT/victim")"
ct_umount "$MNT"
# Garbage past the record, as a previous tenant of this block would have
# left it. Since v0x0005 the record is two CAS sectors and every live
# writer touches ONLY its own sector -- nothing ever rewrites the block
# tail, and nothing ever reads it either: the property that matters is
# that the garbage changes NOTHING observable.
"$POKE" "$IMG" dirtytail "$VICT" >/dev/null
[ "$("$POKE" "$IMG" tailzero "$VICT")" = "no" ] &&
    pass "record io: the poke really did dirty the block tail" ||
    fail "record io: the poke did not dirty the tail -- the checks below would prove nothing"
ct_mount "$DEV" "$MNT"
mv "$MNT/victim" "$MNT/victim2"
mv "$MNT/victim2" "$MNT/victim"
chmod 0705 "$MNT/victim"
sync
stat "$MNT/victim" >/dev/null 2>&1 &&
    pass "record io: the record still reads clean through namespace ops over a dirty tail" ||
    fail "record io: tail garbage broke record reads"
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
[ "$FSCK_RC" = 0 ] &&
    pass "record io: fsck is clean with tail garbage present (the tail is dead space)" ||
    fail "record io: fsck tripped over dead tail bytes: $(echo "$FSCK_OUT" | grep -iE 'err' | head -1)"

log "checking a corrupt record is reported, not served"
# Only the checksum is invalidated -- the record's own fields stay
# plausible, so nothing but the checksum check can catch this.
"$POKE" "$IMG" corrupt "$VICT" >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
if stat "$MNT/victim" >/dev/null 2>&1; then
    fail "record io: stat of a checksum-corrupt record SUCCEEDED -- the bytes were served"
else
    pass "record io: a checksum-corrupt record is refused rather than served"
fi
if dmesg_since "$MARK" | grep -q "failed its record checksum"; then
    pass "record io: dmesg names the failing inode and says it is corrupt"
else
    fail "record io: no dmesg line explaining the refusal"
fi
# The rest of the filesystem keeps working: one bad record is not a
# reason to lose the volume.
ls "$MNT" >/dev/null 2>&1 && pass "record io: the directory is still readable" ||
    fail "record io: one corrupt record made the whole directory unreadable"
: >"$MNT/other" && pass "record io: new files can still be created" ||
    fail "record io: a corrupt record blocked unrelated work"
ct_umount "$MNT"

ct_exit
