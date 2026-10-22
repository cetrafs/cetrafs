#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# rmdir: the emptiness check, and giving everything back
#
# The dangerous failure here is one-directional: an emptiness check that
# stops too early destroys a directory that is NOT empty, orphaning
# everything in it. The check walks the victim's dirent blocks skipping
# '.' and '..', so the case that would catch a short walk is a directory
# whose only surviving entry lives in a LATE block -- which is what a
# directory that was filled and then mostly emptied looks like, and what
# nothing tested.
#
# The other half is reclamation: a directory that grew past its four
# inline extents owns an external extent leaf as well as its dirent
# blocks, and removing it has to return all of them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 rmdir)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rmdir)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
avail() { df --output=avail "$MNT" | tail -1; }
FREE_START="$(avail)"

log "a surviving entry in a late block still makes the directory non-empty"
mkdir "$MNT/late"
for i in $(seq 1 200); do : >"$MNT/late/f$i"; done
for i in $(seq 1 199); do rm "$MNT/late/f$i"; done
[ "$(ls "$MNT/late")" = "f200" ] && pass "one entry left, and it is not in the first block" ||
    fail "setup: '$(ls "$MNT/late" | tr '\n' ' ')' remains"
LATE_GONE=no
if rmdir "$MNT/late" 2>/dev/null; then
    fail "rmdir destroyed a directory that still had an entry in a later block"
    LATE_GONE=yes
else
    pass "rmdir refuses: the walk reaches past the first dirent block"
fi
# Guarded: on a build where the assertion above failed, the directory is
# already gone and an unguarded rm would abort the suite, taking every
# later section with it and printing no FAIL for any of them.
if [ "$LATE_GONE" = "no" ]; then
    rm "$MNT/late/f200"
    rmdir "$MNT/late" && pass "rmdir succeeds once that entry is gone" ||
        fail "rmdir still refuses an empty directory"
fi

log "a directory holding only a subdirectory is non-empty"
mkdir -p "$MNT/a/b"
rmdir "$MNT/a" 2>/dev/null && fail "rmdir removed a directory containing a subdirectory" ||
    pass "rmdir refuses a directory whose only entry is a subdirectory"
rmdir "$MNT/a/b"
rmdir "$MNT/a" && pass "...and succeeds once the child is gone" || fail "rmdir failed after the child was removed"

log "the parent gets its link back"
mkdir "$MNT/p"
BEFORE="$(stat -c '%h' "$MNT")"
mkdir "$MNT/p2"
[ "$(stat -c '%h' "$MNT")" = "$((BEFORE + 1))" ] || fail "setup: the parent's nlink did not rise"
rmdir "$MNT/p2"
[ "$(stat -c '%h' "$MNT")" = "$BEFORE" ] && pass "rmdir drops the parent's nlink back" ||
    fail "parent nlink is $(stat -c '%h' "$MNT"), expected $BEFORE"
rmdir "$MNT/p"

log "everything a grown directory owned comes back"
mkdir "$MNT/big"
# Past four inline extents, so the directory owns an external extent
# leaf block as well as its dirent blocks.
for i in $(seq 1 300); do : >"$MNT/big/f$i"; done
for i in $(seq 1 300); do rm "$MNT/big/f$i"; done
rmdir "$MNT/big"
sync
[ "$(avail)" = "$FREE_START" ] &&
    pass "free space is back to where it started ($FREE_START blocks)" ||
    fail "free space is $(avail), started at $FREE_START -- a dirent block or the extent leaf leaked"

log "a removed directory cannot be used through an already-open fd"
mkdir "$MNT/doomed"
OUT="$(python3 - "$MNT" <<'PY'
import os, sys, errno
mnt = sys.argv[1]
d = os.open(mnt + "/doomed", os.O_RDONLY | os.O_DIRECTORY)
os.rmdir(mnt + "/doomed")
try:
    os.close(os.open("new", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=d))
    print("CREATED")
except OSError as e:
    print("create=" + errno.errorcode.get(e.errno, str(e.errno)))
print("listdir=" + repr(os.listdir(d)))
os.close(d)
PY
)"
case "$OUT" in
*CREATED*) fail "a file was created inside a directory that had already been removed" ;;
*create=ENOENT*) pass "creating inside a removed directory is refused" ;;
*) fail "unexpected: $OUT" ;;
esac
echo "$OUT" | grep -q "listdir=\[\]" && pass "a removed directory reads as empty" ||
    fail "a removed directory still lists entries: $OUT"

log "the obvious refusals"
: >"$MNT/afile"
rmdir "$MNT/afile" 2>/dev/null && fail "rmdir removed a regular file" || pass "rmdir of a non-directory is refused"
rmdir "$MNT" 2>/dev/null && fail "rmdir removed the mount root" || pass "rmdir of the mount root is refused"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
