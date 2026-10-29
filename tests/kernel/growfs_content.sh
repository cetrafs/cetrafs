#!/usr/bin/env bash
# a grow preserves every file, directory, link, mode, owner and xattr exactly
#
# kernel/growfs.sh proves the GEOMETRY of a grow: capacity appears, the
# new Block Groups are usable, nothing overlaps. It checks file content
# with md5 only, over a flat directory of identical 16 MiB files. That
# leaves the whole namespace untested: a grow that relocated the tables
# correctly but dropped a directory, flattened a mode bit, lost a
# symlink target or broke a hard link would pass it completely.
#
# So this suite builds a deliberately awkward tree -- nested
# directories, empty and sub-block and block-boundary files, symlinks,
# hard links, setuid/setgid/sticky bits, non-root ownership, xattrs --
# takes a full manifest of it, grows the volume, and requires the
# manifest to come back byte-identical. Not "the files are still
# readable": the same set, no more and no fewer, with the same metadata.
#
# Both manifests are taken AFTER a umount/mount cycle, so each is a
# genuine read from the device. An earlier version compared a
# page-cache manifest against a post-grow disk manifest, which would
# have blamed the grow for any difference that was really just
# writeback.
#
# The volume is 560 MiB, not the 512 MiB a small-disk test would
# suggest: the smallest Block Group this filesystem will format is
# 512 MiB and the metadata prefix sits in front of it, so 512 MiB
# cannot hold a cetrafs at all (mkfs says "no space for any BG"). 560 is
# the floor every other suite in this tree uses.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 1400 growcontent)"
MNT="$(ct_mnt growcontent)"
WORK="$(ct_mnt growcontentwork)"

# A manifest line per path: type, mode, uid, gid, nlink, size, name, and
# the symlink target. Sorted, so the comparison is order-independent.
# Content hashes and xattrs are appended as their own lines.
manifest() {
    local root="$1" out="$2"
    (
        cd "$root"
        find . -printf '%y %m %U %G %n %s %p -> %l\n' | sort
        find . -type f -printf '%p\n' | sort | while read -r f; do
            printf 'MD5 %s %s\n' "$(md5sum < "$f" | cut -d' ' -f1)" "$f"
        done
        # Python's os.listxattr/os.getxattr, not getfattr: the `attr`
        # package is not a dependency of this test suite and the other
        # xattr suites here already take this route.
        find . \( -type f -o -type d \) -printf '%p\n' | sort |
            python3 -c '
import os, sys
for line in sys.stdin:
    p = line.rstrip("\n")
    try:
        names = sorted(os.listxattr(p))
    except OSError:
        continue
    for n in names:
        try:
            v = os.getxattr(p, n)
        except OSError:
            continue
        print("XATTR", p, n, v.hex())
'
    ) > "$out"
}

log "building an awkward tree on a 560 MiB volume"
ct_mkfs "$DEV" -s 560M -b 512 -z 1 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir -p "$MNT/a/b/c" "$MNT/a/b/d" "$MNT/empty_dir" "$MNT/perms"
# Sizes that straddle the 4 KiB block boundary in both directions, plus
# a genuinely empty file and one large enough to need an extent tree.
: > "$MNT/a/zero_byte"
printf 'x' > "$MNT/a/one_byte"
dd if=/dev/urandom of="$MNT/a/b/under_block" bs=1 count=4095 status=none
dd if=/dev/urandom of="$MNT/a/b/exact_block" bs=1 count=4096 status=none
dd if=/dev/urandom of="$MNT/a/b/over_block" bs=1 count=4097 status=none
dd if=/dev/urandom of="$MNT/a/b/c/one_mib" bs=1M count=1 status=none
dd if=/dev/urandom of="$MNT/a/b/d/sixteen_mib" bs=1M count=16 status=none
for i in 0 1 2 3 4 5 6 7 8 9; do
    dd if=/dev/urandom of="$MNT/bulk_$i" bs=1M count=8 status=none
done

ln -s b/c "$MNT/a/rel_symlink"
ln -s /etc/hostname "$MNT/a/abs_symlink"
ln "$MNT/a/b/exact_block" "$MNT/a/b/hardlink_to_exact"

chmod 4755 "$MNT/perms/setuid_file" 2>/dev/null || : > "$MNT/perms/setuid_file"
chmod 4755 "$MNT/perms/setuid_file"
: > "$MNT/perms/setgid_file"; chmod 2755 "$MNT/perms/setgid_file"
: > "$MNT/perms/private";     chmod 0600 "$MNT/perms/private"
: > "$MNT/perms/world";       chmod 0777 "$MNT/perms/world"
: > "$MNT/perms/odd";         chmod 0741 "$MNT/perms/odd"
chmod 1777 "$MNT/perms"
chmod 0750 "$MNT/a/b/c"
chown 1000:1000 "$MNT/perms/private" "$MNT/a/b/c" 2>/dev/null || skip "chown unavailable"
chown 65534:65534 "$MNT/a/one_byte" 2>/dev/null || true

python3 -c '
import os, sys
os.setxattr(sys.argv[1], b"user.grow_test", b"survives")
os.setxattr(sys.argv[2], b"user.dir_attr", b"on-a-directory")
' "$MNT/a/b/exact_block" "$MNT/a/b" &&
    pass "xattrs set on a file and a directory before the grow" ||
    fail "could not set the xattrs this suite is supposed to preserve"

sync
n_before="$(find "$MNT" | wc -l)"
ct_umount "$MNT"

log "fsck, then manifest the volume as it reads from the device"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "pre-grow volume is clean" || fail "pre-grow volume is not clean"
ct_mount "$DEV" "$MNT"
manifest "$MNT" "$WORK/before"
ct_umount "$MNT"
[ -s "$WORK/before" ] && pass "manifest captured $(wc -l < "$WORK/before") lines across $n_before paths" ||
    fail "manifest is empty -- the comparison below would prove nothing"

# The manifest is the whole test, so its CONTENT is asserted too. A
# find(1) that stopped emitting modes, or an xattr read that silently
# returned nothing, would leave the comparison below passing happily
# over a manifest that no longer describes anything.
grep -q '^MD5 ' "$WORK/before" && pass "manifest contains content hashes" ||
    fail "manifest has no MD5 lines -- content is not actually being compared"
grep -q '^XATTR ' "$WORK/before" && pass "manifest contains xattrs" ||
    fail "manifest has no XATTR lines -- xattrs are not actually being compared"
grep -qE '^f 4755 ' "$WORK/before" && pass "manifest records mode bits (setuid file is in it)" ||
    fail "manifest does not record modes -- permissions are not actually being compared"

log "growing to the full device"
if out="$(ct_growfs "$DEV" 2>&1)"; then
    pass "growfs completed"
else
    fail "growfs failed: $out"
fi
ct_fsck "$DEV" >/dev/null 2>&1 && pass "grown volume is clean" || fail "grown volume is not clean"

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
manifest "$MNT" "$WORK/after"

if diff -u "$WORK/before" "$WORK/after" > "$WORK/diff" 2>&1; then
    pass "the entire tree is byte-identical after the grow: names, types, modes, owners, link counts, sizes, symlink targets, content hashes and xattrs"
else
    fail "the grow changed the tree: $(head -20 "$WORK/diff" | tr '\n' ' ')"
fi

# Stated separately from the diff so a failure says WHICH way it went.
n_after="$(find "$MNT" | wc -l)"
[ "$n_before" = "$n_after" ] && pass "path count unchanged ($n_before)" ||
    fail "path count changed across the grow: $n_before -> $n_after"

# The diff covers mode bits, but setuid/setgid are the ones a filesystem
# silently drops, so they get their own named assertion.
[ "$(stat -c %a "$MNT/perms/setuid_file")" = "4755" ] && pass "setuid bit survived" ||
    fail "setuid bit lost: $(stat -c %a "$MNT/perms/setuid_file")"
[ "$(stat -c %a "$MNT/perms/setgid_file")" = "2755" ] && pass "setgid bit survived" ||
    fail "setgid bit lost: $(stat -c %a "$MNT/perms/setgid_file")"
[ "$(stat -c %a "$MNT/perms")" = "1777" ] && pass "sticky bit on a directory survived" ||
    fail "sticky bit lost: $(stat -c %a "$MNT/perms")"
[ "$(stat -c %u:%g "$MNT/perms/private")" = "1000:1000" ] && pass "non-root ownership survived" ||
    fail "ownership lost: $(stat -c %u:%g "$MNT/perms/private")"
[ "$(stat -c %h "$MNT/a/b/exact_block")" = "2" ] && pass "hard link count survived" ||
    fail "hard link broken: nlink=$(stat -c %h "$MNT/a/b/exact_block")"
[ "$(readlink "$MNT/a/rel_symlink")" = "b/c" ] && pass "relative symlink target survived" ||
    fail "symlink target changed: $(readlink "$MNT/a/rel_symlink")"

# And the tree must still be intact once the GROWN space has been used,
# which is when a misplaced new Block Group would write over it.
log "filling the grown space, then re-checking the whole tree"
w=0
while dd if=/dev/urandom of="$MNT/grown_$w" bs=1M count=16 status=none 2>/dev/null; do
    w=$((w + 1))
    [ "$w" -gt 200 ] && break
done
sync
[ "$w" -gt 4 ] && pass "wrote $w files into the grown space" || fail "grown space took only $w files"

rm -f "$MNT"/grown_*
sync
manifest "$MNT" "$WORK/after2"
if diff -q "$WORK/before" "$WORK/after2" >/dev/null 2>&1; then
    pass "the tree is still byte-identical after the grown space was filled and released"
else
    fail "filling the grown space changed the original tree: $(diff "$WORK/before" "$WORK/after2" | head -10 | tr '\n' ' ')"
fi

# ------------------------------------------- does the diff discriminate?
#
# Every comparison above passes against correct code, which says nothing
# about whether it would NOTICE a difference. One mode bit is flipped
# here and the same manifest comparison is required to FAIL. If this
# block reports that the manifest matched anyway, every green line above
# is decorative (tests/README.md).
log "discrimination: flip one mode bit and require the comparison to notice"
chmod 0644 "$MNT/perms/world"
manifest "$MNT" "$WORK/tampered"
if diff -q "$WORK/before" "$WORK/tampered" >/dev/null 2>&1; then
    fail "the manifest did not notice a changed mode bit -- the comparison proves nothing"
else
    pass "the manifest notices a single changed mode bit"
fi
chmod 0777 "$MNT/perms/world"

# And a changed BYTE, which is a different code path through the
# manifest (the MD5 lines rather than the find(1) lines).
printf 'tamper' | dd of="$MNT/a/b/exact_block" bs=1 seek=100 conv=notrunc status=none
sync
manifest "$MNT" "$WORK/tampered2"
if diff -q "$WORK/before" "$WORK/tampered2" >/dev/null 2>&1; then
    fail "the manifest did not notice a changed byte -- content hashing proves nothing"
else
    pass "the manifest notices a single changed byte"
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "volume is clean at the end" || fail "volume is not clean at the end"

ct_exit
