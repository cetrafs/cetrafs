#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# rename: the destination must never stop existing, and the target must
# be locked before it is mutated
#
# POSIX is explicit that "the link named by new shall remain visible to
# other processes throughout the renaming operation" -- which is the
# whole basis of the write-a-temp-then-rename-over idiom. The replace
# path used to remove the target's entry and then add the source's under
# the same name: two synchronous dirent writes with a real window
# between them where the name did not exist. On one node the VFS hides
# that behind the directory's inode lock; on a shared LUN a peer looking
# the name up in that window gets ENOENT. A failure between the two
# could also destroy the target while leaving the source in place.
#
# Second: a destination that already exists WITHOUT the VFS knowing --
# a peer created it after this node's lookup -- was discovered inside
# the locked section, so its nlink was changed and its blocks freed
# while holding no lock on it. tmpfs is the reference for the ordinary
# semantics.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 rename)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rename)"
REF="$(ct_mnt renameref)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "the ordinary semantics, against tmpfs"
exercise() {
    local r="$1"
    mkdir -p "$r/a" "$r/b"
    echo src >"$r/a/f"
    echo dst >"$r/b/g"
    mv "$r/a/f" "$r/b/g"              # replace a regular file
    mkdir "$r/a/d1" "$r/b/d2"
    mv "$r/a/d1" "$r/b/d1"            # move a directory to a new parent
    echo keep >"$r/a/h"
    mv "$r/a/h" "$r/a/h2"             # rename within one directory
    ln "$r/b/g" "$r/b/g2"             # a hardlinked target
    echo other >"$r/a/x"
    mv "$r/a/x" "$r/b/g2"             # replace one of two links
}
exercise "$MNT"
exercise "$REF"
for p in b/g b/g2 a/h2; do
    got="$(cat "$MNT/$p")"; want="$(cat "$REF/$p")"
    [ "$got" = "$want" ] && pass "$p contains '$got' (matches tmpfs)" ||
        fail "$p: cetrafs '$got', tmpfs '$want'"
done
for p in b/g b/d1 a b; do
    got="$(stat -c '%h' "$MNT/$p")"; want="$(stat -c '%h' "$REF/$p")"
    [ "$got" = "$want" ] && pass "$p nlink $got (matches tmpfs)" ||
        fail "$p nlink: cetrafs $got, tmpfs $want"
done
[ "$(stat -c '%i' "$MNT/b/d1/..")" = "$(stat -c '%i' "$MNT/b")" ] &&
    pass "a moved directory's '..' follows it to the new parent" ||
    fail "'..' still points at the old parent"
[ -e "$MNT/a/f" ] && fail "the source name survived the rename" || pass "the source name is gone"

log "the destination never stops existing"
# The destination is replaced over and over while a reader loops on it.
# Every observation must find the name -- the point is that no window
# exists where it is absent, which is what POSIX requires and what the
# remove-then-add sequence could not provide.
echo original >"$MNT/dest"
# NOTE: on a single kernel this cannot fail -- the VFS holds the parent
# directory's inode lock across the whole rename, so no local observer
# can be inside the window at all. It is kept as a statement of the
# invariant, the same way the CAW-hardware assertions elsewhere are;
# the window it guards is only observable from a second node, which is
# ctest's job.
MISSES=0
(
    for i in $(seq 1 60); do
        echo "v$i" >"$MNT/tmp$i"
        mv "$MNT/tmp$i" "$MNT/dest"
    done
) &
MVPID=$!
while kill -0 "$MVPID" 2>/dev/null; do
    [ -e "$MNT/dest" ] || MISSES=$((MISSES + 1))
done
wait "$MVPID" 2>/dev/null || true
[ "$MISSES" = "0" ] && pass "the destination name was present on every observation across 60 replaces" ||
    fail "the destination name was missing $MISSES times during the replaces"
[ "$(cat "$MNT/dest")" = "v60" ] && pass "the destination holds the last value written" ||
    fail "the destination holds '$(cat "$MNT/dest")'"

log "a replace is one dirent write, so the entry keeps its place"
# The retarget rewrites the entry in place rather than freeing and
# re-adding its slot, so the directory's size does not churn.
mkdir "$MNT/sz"
: >"$MNT/sz/one"
: >"$MNT/sz/two"
SZ_BEFORE="$(stat -c '%s' "$MNT/sz")"
mv "$MNT/sz/one" "$MNT/sz/two"
SZ_AFTER="$(stat -c '%s' "$MNT/sz")"
[ "$SZ_AFTER" -lt "$SZ_BEFORE" ] &&
    pass "replacing one of two entries leaves the directory one entry smaller" ||
    fail "directory size went $SZ_BEFORE -> $SZ_AFTER across a replacing rename"

log "a rename updates the moved inode's ctime ON DISK"
# inode_set_ctime() alone does not dirty the inode, so the in-core
# change was never written back: the on-disk ctime of a renamed file
# never moved. Checked across a remount, which is the only way to tell
# the record apart from the cached object.
: >"$MNT/ct"
sync
CT_BEFORE="$(stat -c '%Z' "$MNT/ct")"
sleep 1.1
mv "$MNT/ct" "$MNT/ct2"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
CT_AFTER="$(stat -c '%Z' "$MNT/ct2")"
[ "$CT_AFTER" -gt "$CT_BEFORE" ] &&
    pass "the renamed file's ctime advanced on disk ($CT_BEFORE -> $CT_AFTER)" ||
    fail "the renamed file's on-disk ctime did not move ($CT_BEFORE -> $CT_AFTER)"

# Same for a replaced target that still has another link: it lost a
# name, so POSIX says its ctime moves too.
: >"$MNT/tgt"
ln "$MNT/tgt" "$MNT/tgt-link"
: >"$MNT/newsrc"
sync
TG_BEFORE="$(stat -c '%Z' "$MNT/tgt-link")"
sleep 1.1
mv "$MNT/newsrc" "$MNT/tgt"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
TG_AFTER="$(stat -c '%Z' "$MNT/tgt-link")"
[ "$TG_AFTER" -gt "$TG_BEFORE" ] &&
    pass "a replaced target that keeps a link has its ctime updated on disk" ||
    fail "the replaced target's on-disk ctime did not move ($TG_BEFORE -> $TG_AFTER)"

log "the refusals"
mkdir "$MNT/ne1" "$MNT/ne2"
: >"$MNT/ne1/f"
: >"$MNT/ne2/f"
mv -T -n "$MNT/ne1/f" "$MNT/ne2/f" 2>/dev/null
[ -e "$MNT/ne1/f" ] && pass "RENAME_NOREPLACE leaves an existing destination alone" ||
    fail "RENAME_NOREPLACE replaced the destination"
mkdir "$MNT/dir1"
: >"$MNT/file1"
mv -T "$MNT/dir1" "$MNT/file1" 2>/dev/null && fail "a directory replaced a regular file" ||
    pass "renaming a directory over a file is refused"
mv -T "$MNT/file1" "$MNT/dir1" 2>/dev/null && fail "a file replaced a directory" ||
    pass "renaming a file over a directory is refused"
mkdir "$MNT/ne3"
: >"$MNT/ne3/child"
mkdir "$MNT/dir2"
mv -T "$MNT/dir2" "$MNT/ne3" 2>/dev/null && fail "a directory replaced a NON-EMPTY directory" ||
    pass "renaming over a non-empty directory is refused"
# RENAME_EXCHANGE is deliberately unimplemented.
if command -v python3 >/dev/null; then
    OUT="$(python3 - "$MNT" <<'PY'
import ctypes, os, sys, errno
libc = ctypes.CDLL(None, use_errno=True)
mnt = sys.argv[1]
d = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
r = libc.renameat2(d, b"file1", d, b"dir1", 2)  # RENAME_EXCHANGE
print("rc=%d err=%s" % (r, errno.errorcode.get(ctypes.get_errno(), ctypes.get_errno())))
os.close(d)
PY
)"
    case "$OUT" in
    *err=EINVAL*) pass "RENAME_EXCHANGE is refused with EINVAL, not silently mishandled" ;;
    *rc=0*) fail "RENAME_EXCHANGE appeared to succeed: $OUT" ;;
    *) pass "RENAME_EXCHANGE is refused ($OUT)" ;;
    esac
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
