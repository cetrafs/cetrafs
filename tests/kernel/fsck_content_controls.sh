#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's content and namespace passes really detect corruption
#
# Negative controls with the module in the picture: each fault is
# injected into a real volume and fsck must report THAT fault and exit
# nonzero. Disabling a check must make its own assertion fail -- an
# exit-code-only control proves nothing here, since several faults are
# caught by more than one pass.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking fsck's content passes actually DETECT corruption"
# fsck now walks the inode table, collects every extent, and reconciles
# them against the data bitmaps. A checker that has never been seen to
# fail proves nothing, so each class it claims to catch is injected here
# deliberately. These are the two passes that would have caught real
# bugs from this project's history: the 128 MiB leak (blocks marked used
# that nothing references) and cross-file block overlap.
CPOKE="$(ct_helper corrupt_poke)"
FSK_IMG="$(mktemp /tmp/cetrafs-fsk-XXXXXX.img)"
FSK_MNT="$(mktemp -d /tmp/cetrafs-fsk-mnt-XXXXXX)"

fsk_build() {
    rm -f "$FSK_IMG"; truncate -s 560M "$FSK_IMG"
    FSK_LOOPDEV="$(losetup --find --show "$FSK_IMG")"
    "$ROOT/userspace/mkfs.cetra" "$FSK_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    mount -t cetrafs "$FSK_LOOPDEV" "$FSK_MNT" ||
        fail "fsck content: could not mount the scratch volume (results would be meaningless)"
    grep -q " $FSK_MNT cetrafs " /proc/self/mounts ||
        fail "fsck content: $FSK_MNT is not a cetrafs mount -- files would land on the host fs"
    for i in 1 2 3 4 5 6; do dd if=/dev/zero of="$FSK_MNT/g$i" bs=4096 count=2 status=none; done
    sync
    # The overlap case pokes inodes 3 and 4, so prove they exist and are
    # the files we think they are before relying on them.
    FSK_INO3="$(stat -c '%i' "$FSK_MNT/g2")"
    FSK_INO4="$(stat -c '%i' "$FSK_MNT/g3")"
    umount "$FSK_MNT"
}

fsk_build
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
"$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" >/dev/null 2>&1 &&
    pass "fsck content: a healthy volume passes the content passes" ||
    fail "fsck content: healthy volume wrongly reported as corrupt"
losetup -d "$FSK_LOOPDEV"

fsk_build
"$CPOKE" "$FSK_IMG" bitset 0 900 >/dev/null
# fsck exits non-zero on corruption, which is the POINT here -- so
# swallow the status or `set -e` aborts the whole suite silently.
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "referenced by no inode" &&
    pass "fsck content: detects a leaked block (marked used, referenced by nothing)" ||
    fail "fsck content: leaked block unreported -- the 128 MiB-leak class is invisible again; fsck said: $FSK_OUT"
losetup -d "$FSK_LOOPDEV"

fsk_build
"$CPOKE" "$FSK_IMG" bitclr 0 1 >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
if "$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" >/dev/null 2>&1; then
    fail "fsck content: a block in use but marked FREE was not reported"
else
    pass "fsck content: detects a block in use but marked free (it would be handed out twice)"
fi
losetup -d "$FSK_LOOPDEV"

fsk_build
# Point two inodes at the same physical block: the worst corruption this
# filesystem can suffer, because it is silent and compounding.
"$CPOKE" "$FSK_IMG" extent "$FSK_INO3" 9000 >/dev/null
"$CPOKE" "$FSK_IMG" extent "$FSK_INO4" 9000 >/dev/null
# fsck exits non-zero on corruption, which is the POINT here -- so
# swallow the status or `set -e` aborts the whole suite silently.
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "cross-file overlap" &&
    pass "fsck content: detects two inodes sharing a block (cross-file overlap)" ||
    fail "fsck content: cross-file overlap undetected (inodes $FSK_INO3/$FSK_INO4); fsck said: $FSK_OUT"
losetup -d "$FSK_LOOPDEV"

fsk_build
# The signature a LOST DIRECTORY ENTRY leaves on disk: the inode is still
# allocated, checksum-clean and holding good extents, but nothing names
# it. This is precisely what a lost directory entry leaves behind, and
# until the namespace pass existed no tool could see it -- the file
# simply "vanished".
"$CPOKE" "$FSK_IMG" dirent 1 g4 >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "NO directory entry names it" &&
    pass "fsck namespace: detects an allocated-but-unreachable inode (a lost dirent)" ||
    fail "fsck namespace: a lost directory entry went undetected; fsck said: $FSK_OUT"
losetup -d "$FSK_LOOPDEV"

fsk_build_subdir() {
    rm -f "$FSK_IMG"; truncate -s 560M "$FSK_IMG"
    FSK_LOOPDEV="$(losetup --find --show "$FSK_IMG")"
    "$ROOT/userspace/mkfs.cetra" "$FSK_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    mount -t cetrafs "$FSK_LOOPDEV" "$FSK_MNT" ||
        fail "fsck namespace: could not mount the scratch volume"
    grep -q " $FSK_MNT cetrafs " /proc/self/mounts ||
        fail "fsck namespace: $FSK_MNT is not a cetrafs mount -- results would be meaningless"
    mkdir "$FSK_MNT/sub"
    sync
    FSK_SUBINO="$(stat -c '%i' "$FSK_MNT/sub")"
    umount "$FSK_MNT"
}

# '.' and '..' on a NON-root directory. Root's pair has its own dedicated
# (stricter) check with controls in tests/fsck_test.sh, but that one runs
# on a root-only image and cannot reach the general case -- which needs a
# subdirectory, which needs a mount, which is why this lives here.
#
# A rename that moved a directory without rewriting '..' leaves exactly
# this shape, and nothing in fsck looked at it before: the reference
# tally deliberately skips both entries.
fsk_build_subdir
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
"$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" >/dev/null 2>&1 &&
    pass "fsck namespace: a volume with a healthy subdirectory passes" ||
    fail "fsck namespace: healthy subdirectory wrongly reported as corrupt"
losetup -d "$FSK_LOOPDEV"

fsk_build_subdir
# Point the subdirectory's '..' at itself instead of at root.
"$CPOKE" "$FSK_IMG" repoint "$FSK_SUBINO" ".." "$FSK_SUBINO" >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "has '\.\.' naming inode" &&
    pass "fsck namespace: detects a subdirectory whose '..' does not name its parent" ||
    fail "fsck namespace: a wrong '..' went undetected; fsck said: $FSK_OUT"
losetup -d "$FSK_LOOPDEV"

fsk_build_subdir
# And '.' naming something other than the directory itself.
"$CPOKE" "$FSK_IMG" repoint "$FSK_SUBINO" "." 1 >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "has '\.' naming inode" &&
    pass "fsck namespace: detects a subdirectory whose '.' does not name itself" ||
    fail "fsck namespace: a wrong '.' went undetected; fsck said: $FSK_OUT"
losetup -d "$FSK_LOOPDEV"

# A directory's LINK COUNT against the number of subdirectories it
# actually contains. Checked by nothing until U3-U6, and the control
# that first shipped with it was built on an empty root -- where a
# correct implementation and one that counts no subdirectories at all
# agree, so it passed against the broken version. Both directions are
# needed, on a directory that really HAS a subdirectory.
NLINK_POKE="$(mktemp /tmp/cetrafs-fsk-nlpoke-XXXXXX)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$NLINK_POKE" "$ROOT/tests/helpers/inode_block_poke.c" || exit 2

fsk_build_subdir
# Root now contains exactly one subdirectory, so its nlink must be 3.
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
"$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" >/dev/null 2>&1 &&
    pass "fsck nlink: a parent holding one subdirectory passes with nlink 3" ||
    fail "fsck nlink: a healthy parent with a subdirectory was reported: $("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 | grep -i err | head -1)"
losetup -d "$FSK_LOOPDEV"

fsk_build_subdir
"$NLINK_POKE" "$FSK_IMG" nlink 1 9 >/dev/null 2>&1
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "nlink=9 but contains 1 subdirectory" &&
    pass "fsck nlink: a parent claiming 9 links while holding one subdirectory is reported" ||
    fail "fsck nlink: the wrong link count went undetected; fsck said: $(echo "$FSK_OUT" | grep -i err | head -1)"
losetup -d "$FSK_LOOPDEV"
rm -f "$NLINK_POKE"

# REACHABILITY FROM THE ROOT, as opposed to "named by something".
#
# The unreachable check asks whether any directory entry names an inode.
# Two directories naming each other are each named by something and
# neither is reachable, so a detached subtree -- the residue of an
# interrupted rename, or a '..' never fixed up -- passed every check
# this tool made while the space it holds was unreachable forever.
fsk_build_tree() {
    rm -f "$FSK_IMG"; truncate -s 560M "$FSK_IMG"
    FSK_LOOPDEV="$(losetup --find --show "$FSK_IMG")"
    "$ROOT/userspace/mkfs.cetra" "$FSK_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    mount -t cetrafs "$FSK_LOOPDEV" "$FSK_MNT" ||
        fail "fsck reachability: could not mount the scratch volume"
    grep -q " $FSK_MNT cetrafs " /proc/self/mounts ||
        fail "fsck reachability: $FSK_MNT is not a cetrafs mount -- results would be meaningless"
    mkdir -p "$FSK_MNT/x/y/z"
    sync
    FSK_X="$(stat -c '%i' "$FSK_MNT/x")"
    FSK_Y="$(stat -c '%i' "$FSK_MNT/x/y")"
    FSK_Z="$(stat -c '%i' "$FSK_MNT/x/y/z")"
    umount "$FSK_MNT"
}

fsk_build_tree
# Captured first, grepped after: fsck's exit status is itself a finding,
# and under `set -o pipefail` a pipeline inherits it, so this would fail
# on a correct tool the moment the image had any other fault.
FSK_REACH="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_REACH" | grep -q "every directory is reachable from the root" &&
    pass "fsck reachability: a healthy tree reports every directory reachable" ||
    fail "fsck reachability: a healthy three-deep tree was not reported reachable"
losetup -d "$FSK_LOOPDEV"

fsk_build_tree
# Root's entry "x" is made to name the GRANDCHILD instead, so nothing
# names x any more: x and y become a detached subtree hanging off
# nothing, while every inode involved is still named by something and
# every link count still adds up.
"$CPOKE" "$FSK_IMG" repoint 1 x "$FSK_Z" >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "is not reachable from the root" &&
    pass "fsck reachability: detects a detached subtree" ||
    fail "fsck reachability: a detached subtree went undetected; fsck said: $(echo "$FSK_OUT" | grep -i err | head -2)"
# ...and it reports the TOP of it, once, not every directory underneath.
DETACHED_N="$(echo "$FSK_OUT" | grep -c "is not reachable from the root" || true)"
[ "$DETACHED_N" = "1" ] &&
    pass "fsck reachability: reports the top of the detached subtree once, not every directory under it" ||
    fail "fsck reachability: reported $DETACHED_N detached directories, expected 1"
losetup -d "$FSK_LOOPDEV"

fsk_build_tree
# A true CYCLE, and the case this check exists for: root's "x" is
# repointed at z (so nothing names x), y's "z" is repointed at x (so y
# names x), and all three '..' entries are fixed up to match. x's parent
# is y and y's parent is x -- each named by something, each with a
# correct '..', correct link counts and a correct reference tally, and
# NEITHER reachable from the root.
#
# Every other check in the tool passes on this image. That is the point:
# it is the one fault nothing else can see, so the assertion below is
# that the cycle report is the ONLY error, not merely that it appears.
"$CPOKE" "$FSK_IMG" repoint 1 x "$FSK_Z" >/dev/null
"$CPOKE" "$FSK_IMG" repoint "$FSK_Y" z "$FSK_X" >/dev/null
"$CPOKE" "$FSK_IMG" repoint "$FSK_X" .. "$FSK_Y" >/dev/null
"$CPOKE" "$FSK_IMG" repoint "$FSK_Y" .. "$FSK_X" >/dev/null
"$CPOKE" "$FSK_IMG" repoint "$FSK_Z" .. 1 >/dev/null
blockdev --flushbufs "$FSK_LOOPDEV" 2>/dev/null || true
FSK_OUT="$("$ROOT/userspace/fsck.cetra" "$FSK_LOOPDEV" 2>&1 || true)"
echo "$FSK_OUT" | grep -q "parent CYCLE that never reaches the root" &&
    pass "fsck reachability: detects a detached cycle (each named, neither reachable)" ||
    fail "fsck reachability: a detached cycle went undetected; fsck said: $(echo "$FSK_OUT" | grep -i err | head -3)"
OTHER="$(echo "$FSK_OUT" | grep "^ERR" | grep -vc "parent CYCLE" || true)"
[ "$OTHER" = "0" ] &&
    pass "fsck reachability: the cycle is the ONLY fault reported -- nothing else in fsck can see it" ||
    fail "fsck reachability: $OTHER other error(s) too, so this control does not isolate the check: $(echo "$FSK_OUT" | grep '^ERR' | grep -v 'parent CYCLE' | head -2)"
losetup -d "$FSK_LOOPDEV"

rm -f "$FSK_IMG" "$CPOKE"; rmdir "$FSK_MNT"


ct_exit
