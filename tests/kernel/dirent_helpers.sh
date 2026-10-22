#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the dirent helpers, and a directory that has REALLY spilled to depth 1
#
# The finding that prompted this suite is a coverage one. The run-aware
# allocator places a new extent at the head of a large free
# run, so a directory grown on its own stays in ONE contiguous extent
# however many entries it has -- measured: 600 entries, 41 blocks,
# eh_depth still 0. Every existing test built its big directories that
# way, so **the depth-1 external extent leaf path for directories had
# never been exercised**, despite being described as covered.
#
# Reaching it takes a second directory growing alongside the first, so
# their blocks interleave and the extent array fills. That is what this
# suite does, and it asserts the SHAPE rather than the entry count --
# "this directory is big" is not the same claim as "this directory
# spilled".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"
G="$(ct_helper getdents_probe)"

IMG="$(ct_image 560 dirent)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dirent)"
REF="$(ct_mnt direntref)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "names the format allows, end to end"
N255="$(printf 'n%.0s' $(seq 1 255))"
names=("$N255" "a" "aa" "aaa" "with space" "üñïçø∂é" "-leading-dash" ".hidden")
for n in "${names[@]}"; do
    : >"$MNT/$n"
    : >"$REF/$n"
done
for n in "${names[@]}"; do
    [ -e "$MNT/$n" ] || fail "'${n:0:20}' does not resolve after being created"
done
pass "every name -- including one of exactly 255 characters -- resolves"
GOT="$(ls -A "$MNT" | sort | md5sum)"
WANT="$(ls -A "$REF" | sort | md5sum)"
[ "$GOT" = "$WANT" ] && pass "readdir returns exactly the same set of names as tmpfs" ||
    fail "the name sets differ: $(ls -A "$MNT" | sort | tr '\n' ' ')"
# Prefixes are the case a length-blind comparison would get wrong.
[ "$(stat -c '%i' "$MNT/a")" != "$(stat -c '%i' "$MNT/aa")" ] &&
    pass "names that are prefixes of each other are distinct entries" ||
    fail "'a' and 'aa' resolved to the same inode"
rm "$MNT/$N255"
[ -e "$MNT/$N255" ] && fail "the 255-character name survived removal" ||
    pass "a 255-character name can be removed again"

log "a removed entry's slot is reused, not appended past"
mkdir "$MNT/reuse"
for i in $(seq 1 14); do : >"$MNT/reuse/f$i"; done
BL1="$(stat -c '%b' "$MNT/reuse")"
for i in $(seq 1 14); do rm "$MNT/reuse/f$i"; done
for i in $(seq 1 14); do : >"$MNT/reuse/g$i"; done
BL2="$(stat -c '%b' "$MNT/reuse")"
[ "$BL1" = "$BL2" ] && pass "refilling a directory reuses its slots ($BL1 blocks throughout)" ||
    fail "the directory grew from $BL1 to $BL2 blocks refilling the same number of entries"

log "a directory grown ALONE never spills -- which is why nothing tested the spill"
mkdir "$MNT/solo"
for i in $(seq 1 600); do : >"$MNT/solo/f$i"; done
SOLO_INO="$(stat -c '%i' "$MNT/solo")"

log "a directory whose blocks interleave really does spill"
mkdir "$MNT/frag" "$MNT/noise"
for i in $(seq 1 300); do
    : >"$MNT/frag/f$i"
    : >"$MNT/noise/n$i"
done
FRAG_INO="$(stat -c '%i' "$MNT/frag")"
ct_umount "$MNT"
SOLO_SHAPE="$("$POKE" "$IMG" extents "$SOLO_INO" 2>/dev/null)"
FRAG_SHAPE="$("$POKE" "$IMG" extents "$FRAG_INO" 2>/dev/null)"
case "$SOLO_SHAPE" in
depth=0*) pass "600 entries grown alone: still one extent, depth 0 ($SOLO_SHAPE)" ;;
*) fail "the solo directory's shape is unexpected: $SOLO_SHAPE" ;;
esac
case "$FRAG_SHAPE" in
depth=1*) pass "300 entries grown interleaved: spilled to an external leaf ($FRAG_SHAPE)" ;;
*) fail "the interleaved directory did NOT spill -- this suite is not testing depth 1: $FRAG_SHAPE" ;;
esac

log "everything still works on a directory that really is depth 1"
ct_mount "$DEV" "$MNT"
COUNT="$("$G" list "$MNT/frag" 256 | sort -u | wc -l)"
[ "$COUNT" = "302" ] && pass "readdir through the external leaf returns all 302 entries" ||
    fail "readdir returned $COUNT unique entries, expected 302"
[ -e "$MNT/frag/f300" ] && pass "lookup finds a name in a late block through the external leaf" ||
    fail "lookup cannot find f300"
rm "$MNT/frag/f150"
: >"$MNT/frag/f150b"
[ -e "$MNT/frag/f150b" ] && [ ! -e "$MNT/frag/f150" ] &&
    pass "remove and re-add work through the external leaf" ||
    fail "remove/add on a depth-1 directory misbehaved"
mv "$MNT/frag/f1" "$MNT/frag/f1-renamed"
[ -e "$MNT/frag/f1-renamed" ] && pass "rename works within a depth-1 directory" ||
    fail "rename inside a depth-1 directory failed"

log "removing a depth-1 directory returns the leaf as well as the blocks"
avail() { df --output=avail "$MNT" | tail -1; }
FREE_BEFORE="$(avail)"
mkdir "$MNT/f2" "$MNT/n2"
for i in $(seq 1 300); do
    : >"$MNT/f2/f$i"
    : >"$MNT/n2/n$i"
done
for i in $(seq 1 300); do
    rm "$MNT/f2/f$i"
    rm "$MNT/n2/n$i"
done
rmdir "$MNT/f2" "$MNT/n2"
sync
[ "$(avail)" = "$FREE_BEFORE" ] &&
    pass "free space is back to where it started, external leaves included" ||
    fail "free space is $(avail), was $FREE_BEFORE -- an extent leaf leaked"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
