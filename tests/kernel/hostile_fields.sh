#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a field that passes its checksum still has to make sense
#
# A CRC proves the bytes are the ones that were written. It proves
# nothing about whether they mean anything, and several fields were
# trusted the moment the checksum passed:
#
#   - a dirent's name_len went straight to dir_emit(), so a length past
#     the 255-byte field copied adjacent kernel memory to userspace;
#   - an xattr's value_len went straight to a memcpy() aimed at a
#     userspace buffer, from a field a quarter the size it could claim;
#   - an extent header's entry count went straight into an array index,
#     and "entries - 1" on zero wrapped to 0xffffffff.
#
# None of these need an attacker. A peer running older or broken code, a
# half-written block that happened to be restamped, a flipped bit inside
# a correctly checksummed structure -- all produce the same thing.
#
# The check now lives where the block is READ, not at each use:
# eh_entries alone has 69 use sites, and a rule every one of them must
# remember is a rule one of them will forget. A block that fails it
# takes the same route as a failed checksum -- retried fresh, then
# refused -- because a lockless reader can catch a writer mid-update and
# see either.
#
# Discrimination: drop cetrafs_blk_struct_ok_magic() from
# cetrafs_blk_tail_valid() and the readdir below walks off the end of
# the name field instead of being refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper corrupt_poke)"

IMG="$(ct_image 560 hostile)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hostile)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
: > "$MNT/d/victim"
: > "$MNT/d/bystander"
DINO="$(stat -c '%i' "$MNT/d")"
sync
ct_umount "$MNT"

# A name_len far past the field, with the tail restamped so the block is
# INTEGRITY-perfect. Without the restamp this would only re-test the
# checksum, which already worked.
"$POKE" "$IMG" namelen "$DINO" victim 4000 >/dev/null ||
    fail "could not poison the dirent (is the directory depth-0?)"
pass "poisoned name_len=4000 behind a valid checksum"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"

# THE assertion. Either the directory is refused or the entry is, but
# what must not happen is a 4000-byte name reaching userspace.
OUT="$(ls -1 "$MNT/d" 2>&1 || true)"
LONGEST=$(printf '%s\n' "$OUT" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')

# A bound, not the discriminator -- see the note below. It holds with
# and without the fix, because the VFS usually turns the over-long name
# into an error of its own; it is here because if it ever STOPS holding,
# that is a leak reaching userspace and nothing else would say so.
[ "$LONGEST" -le 255 ] &&
    pass "no name longer than the field reached userspace (longest: $LONGEST bytes)" ||
    fail "readdir produced a $LONGEST-byte name from a 255-byte field -- adjacent kernel memory went out"

# THE discriminating assertion, and the reason it is a log line rather
# than something more satisfying.
#
# Without the check the harm is a READ past the end of the name field,
# inside the VFS's own memchr(). Nothing observable comes of it on a
# normal kernel: verify_dirent_name() usually finds a '/' somewhere in
# the adjacent memory and returns -EIO, so userspace sees an error and
# no long name -- which is why the bound above passes either way and
# cannot be the discriminator. Seeing the read itself needs KASAN, and
# no kernel in this project's test fleet is built with it.
#
# So what is asserted is that we refused the block BEFORE handing it to
# the VFS at all. With the check removed this line does not appear.
dmesg_since "$MARK" | grep -qiE "impossible entry count|failed its tail checksum|dirent block .* failed" &&
    pass "the block was refused before the VFS ever saw the length" ||
    fail "nothing refused a dirent claiming a 4000-byte name: the length reached verify_dirent_name(), which bounds at PATH_MAX and not NAME_MAX, and read it out of a 255-byte field"

# The volume must stay usable -- refusing one block is not a licence to
# break the mount.
[ -d "$MNT/d" ] && pass "the mount survives a hostile block" || fail "the mount is unusable after one bad block"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 &&
    log "note: fsck accepts the poisoned image (it has its own view)" ||
    pass "fsck also refuses the poisoned dirent"

ct_exit
