#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs grows a MOUNTED volume: new space usable at once, nothing old touched
#
# A live grow (kmod/grow.c) is growfs writing the new Block Groups and
# their table segment past the published end while holding the repair
# claim, then handing the superblock to CETRAFS_IOC_GROW. The kernel
# re-walks what that superblock describes, credits the pool, links the
# segment and swaps block 0 by compare-and-swap, and switches this
# node's layout (fs.c, struct cetrafs_bg_layout).
#
# The volume is filled to ENOSPC first, so "the new space is usable"
# cannot be satisfied by space the old Block Groups still had: every
# block written after the grow comes from a Block Group the grow added,
# taken from the pool by the ordinary claim path. Two grows: the FIRST
# links its segment through the superblock, the SECOND by swapping the
# old tail's next -- the two code paths cetrafs_grow_commit() has.
#
# The originals are verified after each grow AND after the new space
# has been written, as growfs.sh does for the offline path, and fsck
# checks the pool shards against the Block Groups at the end.
#
# DISCRIMINATION: the kernel's re-walk is the only thing between a
# lying growfs and a published lie. CETRAFS_GROWFS_TEST_DESC_SHIFT=-1
# writes correct regions but descriptors naming the Block Group before
# each one; the grow must be refused with nothing published -- same
# superblock bytes, same layout_gen, fsck clean. Proven 2026-11-08 with
# both of the walk's overlap checks removed (Block Group after Block
# Group, segment against Block Group -- either alone catches this
# shift): the lie is published and fsck then finds the overlap.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 2900 growlive)"
MNT="$(ct_mnt growlive)"
WORK="$(ct_mnt growlivework)"
ct_track mnt "$MNT"

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
size_now() { df -B1 --output=size "$MNT" | tail -1 | tr -d ' '; }
sb_sum() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | md5sum; }
fill() { # <prefix> <max files> -> number written before ENOSPC
    local n=0
    while [ "$n" -lt "$2" ] && dd if=/dev/urandom of="$MNT/$1$n" bs=1M count=16 conv=fsync status=none 2>/dev/null; do
        n=$((n + 1))
    done
    rm -f "$MNT/$1$n" # the one that hit ENOSPC, if any
    echo "$n"
}
verify() { # <what>
    sync
    echo 3 >/proc/sys/vm/drop_caches
    (cd "$MNT" && md5sum -c --quiet "$WORK/digests") && pass "$1: every file written so far reads back intact" ||
        fail "$1: data written before this point no longer reads back"
}
digest() { (cd "$MNT" && md5sum "$1"* >>"$WORK/digests"); } # <prefix>, globbed inside the mount

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
: >"$WORK/digests"

log "filling the 600 MiB volume to ENOSPC"
n="$(fill a 200)"
[ "$n" -ge 8 ] && pass "setup: filled with $n files before ENOSPC" || fail "setup: only $n files fit -- not the volume this suite assumes"
dd if=/dev/zero of="$MNT/probe" bs=1M count=16 conv=fsync status=none 2>/dev/null &&
    { fail "setup: the volume still had room after the fill"; rm -f "$MNT/probe"; } ||
    pass "setup: the volume is full"
rm -f "$MNT/probe"
digest a
verify "setup"

grow() { # <tag> <size>
    local tag="$1" size="$2" out gen0 bgs0 size0
    gen0="$(info layout_gen)"; bgs0="$(info block_group_count)"; size0="$(size_now)"
    if out="$(ct_growfs "$DEV" -s "$size" 2>&1)"; then
        grep -q 'completed live' <<<"$out" && pass "$tag: growfs grew the mounted volume live" ||
            fail "$tag: growfs succeeded but not through the live path: $(tail -1 <<<"$out")"
    else
        fail "$tag: the live grow failed: $(grep -m1 -iE 'refus|fail|error' <<<"$out" || tail -1 <<<"$out")"
        return 1
    fi
    [ "$(info layout_gen)" = "$((gen0 + 1))" ] && pass "$tag: layout_gen $gen0 -> $(info layout_gen), without a remount" ||
        fail "$tag: layout_gen is $(info layout_gen) after the grow (was $gen0)"
    [ "$(info block_group_count)" -gt "$bgs0" ] &&
        pass "$tag: this node knows $(info block_group_count) Block Groups (was $bgs0)" ||
        fail "$tag: the node still counts $(info block_group_count) Block Groups"
    [ "$(size_now)" -gt "$size0" ] && pass "$tag: df reports $(size_now) bytes (was $size0)" ||
        fail "$tag: df did not grow ($size0 -> $(size_now))"
}

log "first live grow: 600 MiB -> 1400 MiB (linked through the superblock)"
grow first 1400M
verify "after the first grow"
log "writing into the space it added"
n="$(fill b 40)"
[ "$n" -ge 16 ] && pass "wrote $n x 16 MiB into the new space ($((n * 16)) MiB)" ||
    fail "only $n file(s) fit in the new space -- the added Block Groups are not reachable"
digest b
verify "after writing into the first grow's space"

log "second live grow: -> 2300 MiB (linked from the old tail by compare-and-swap)"
grow second 2300M
n="$(fill c 40)"
[ "$n" -ge 16 ] && pass "wrote $n x 16 MiB into the second grow's space" ||
    fail "only $n file(s) fit after the second grow"
digest c
verify "after writing into the second grow's space"

log "fsck and a remount"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after two live grows (pool shards, chain, aggregates)" ||
    fail "fsck after two live grows: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_mount "$DEV" "$MNT"
verify "after a remount"

log "discrimination: a grow whose descriptors lie must be refused by the kernel"
gen0="$(info layout_gen)"; sum0="$(sb_sum)"
if out="$(CETRAFS_GROWFS_TEST_DESC_SHIFT=-1 ct_growfs "$DEV" 2>&1)"; then
    fail "the kernel published a grow whose descriptors name the wrong Block Groups"
else
    pass "a grow with lying descriptors is refused ($(grep -m1 -o 'refused[^.]*' <<<"$out" || tail -1 <<<"$out"))"
fi
[ "$(sb_sum)" = "$sum0" ] && [ "$(info layout_gen)" = "$gen0" ] &&
    pass "and nothing was published: same superblock, layout_gen $gen0" ||
    fail "a refused grow changed the superblock or the layout"
verify "after the refused grow"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after the refused grow" ||
    fail "fsck after the refused grow: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
