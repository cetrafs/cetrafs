#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck does not repair link counts around a directory it could not read
#
# fsck's namespace pass skipped, in silence, any directory whose extent
# tree a directory cannot have (bad magic, depth past 1). Its names then
# counted for nothing: a file named both there and elsewhere had its
# nlink "repaired" down to the one name fsck could see -- the destructive
# direction, since unlinking that other name then frees an inode the
# unread directory still names. Now the directory is reported and the
# run repairs nothing.
#
# DISCRIMINATION (measured on the old fsck): the directory is not named.
# The nlink drop did not happen in this setup -- the content pass flagged
# the poked record's tree and that alone disabled repair -- so the link
# assertion guards the property without having been seen to fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fsckdir)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckdir)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
echo data >"$MNT/d/f"
ln "$MNT/d/f" "$MNT/g"
sync
DINO="$(stat -c %i "$MNT/d")"
FINO="$(stat -c %i "$MNT/g")"
[ "$(stat -c %h "$MNT/g")" = 2 ] || { fail "setup: file nlink is $(stat -c %h "$MNT/g"), not 2"; ct_exit; }
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the volume is not clean before the poke"; ct_exit; }
pass "setup: inode $FINO has two names, one in directory $DINO"

"$POKE" "$IMG" setdepth "$DINO" 2 2>/dev/null
pass "setup: directory $DINO now has depth 2, checksums restamped"

rc=0
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && pass "fsck reports the volume as damaged (rc=$rc)" || fail "fsck called it clean"
grep -q "directory inode $DINO has an extent tree a directory cannot have" <<<"$OUT" &&
    pass "the unreadable directory is named" ||
    fail "the unreadable directory was skipped in silence: $(grep -E '^ERR' <<<"$OUT" | head -3 | tr '\n' ' ')"
ct_mount "$DEV" "$MNT"
N="$(stat -c %h "$MNT/g")"
ct_umount "$MNT"
[ "$N" = 2 ] && pass "the file keeps both links" ||
    fail "fsck -r lowered the file's nlink to $N around a directory it could not read"
ct_exit
