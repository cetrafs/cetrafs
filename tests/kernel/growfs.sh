#!/usr/bin/env bash
# growfs.cetra grows a volume into space the device already has, without losing or aliasing a block
#
# The design (docs/internal/EXTENDFS-DESIGN.md) grows by RELOCATING the
# ZG table, BG table and pending-free region into a reserve at the end of
# the device, then publishing new offsets in one superblock write. That
# keeps the on-disk format unchanged -- a volume formatted by an older
# build grows in place -- but it means a grow moves structures the rest
# of the filesystem addresses only through superblock fields, and a
# mistake in where the NEW Block Groups start lands them on top of the
# OLD ones.
#
# That failure mode is why this suite is shaped the way it is. A grown
# volume mounts, fscks clean and reads back perfectly even when the new
# regions overlap the old ones -- right up until something writes into
# the new space. So the originals are verified THREE times: before the
# grow, after the grow, and again after the new space has been written.
# Only the third one can catch it, and CETRAFS_GROWFS_TEST_BG_OFFSET
# exists so this suite can prove that (see the discrimination check at
# the end -- without it, the third verify is an assertion nobody has
# measured).
#
# The volume is deliberately small and its single Block Group is filled
# to ENOSPC before growing: the allocator will not touch a new BG while
# the old one still has room, so "the new space is real" cannot be
# tested without first exhausting the old.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# 3200 MiB device, 600 MiB filesystem: one 512 MiB BG now, and room for
# four more. Three is the number that matters -- the SECOND grow is the
# first one that has to step over a superseded tail reserve, and the
# third is what proves that stepping over repeats rather than working
# once. Lives outside /tmp -- see ct_big_image.
DEV="$(ct_big_dev 3200 growfs)"
MNT="$(ct_mnt growfs)"
WORK="$(ct_mnt growfswork)"

fs_blocks() { "$ROOT/userspace/fsck.cetra" "$1" 2>&1 | grep -c . >/dev/null; }

# ---------------------------------------------------------------- setup
log "formatting 600 MiB of a 1400 MiB device"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

size_before="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
log "filling the 512 MiB Block Group to ENOSPC"
i=0
while dd if=/dev/urandom of="$MNT/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 200 ] && break
done
sync
[ "$i" -gt 8 ] && pass "filled the volume with $i files" ||
    fail "only $i files written before ENOSPC -- the volume is not what this suite assumes"

# Measured from the DEVICE, not the page cache. Filling to ENOSPC with
# delayed allocation can leave a file short on disk while the cache
# still holds the bytes the write put there, so a digest taken while
# mounted records the cache and disagrees with every later read. That
# produced intermittent "the grow corrupted my data" failures on a
# different file each time, in a suite where the grow had not touched
# the data at all. Unmount first; then every digest is a disk read.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
( cd "$MNT" && md5sum f* > "$WORK/digests" )
nfiles="$(wc -l < "$WORK/digests")"
ct_umount "$MNT"

log "fsck before the grow"
if out="$(ct_fsck "$DEV" 2>&1)"; then
    pass "ungrown volume is clean"
else
    fail "ungrown volume is not clean: $out"
fi
leaked_before="$(printf '%s' "$out" | grep -oE '[0-9]+ leaked' | grep -oE '^[0-9]+' || echo 0)"

# ------------------------------------------------- negative: live mount
ct_mount "$DEV" "$MNT"
if out="$(ct_growfs "$DEV" 2>&1)"; then
    fail "growfs grew a MOUNTED volume -- the offline premise is the whole mutual-exclusion argument"
elif grep -qi 'mounted' <<<"$out"; then
    pass "growfs refuses a mounted volume, and says so"
else
    pass "growfs refused a mounted volume (for an unstated reason: $out)"
fi
ct_umount "$MNT"

# ------------------------------------------------ negative: past the end
if out="$(ct_growfs "$DEV" -s 99999G 2>&1)"; then
    fail "growfs accepted a target larger than the device"
else
    pass "growfs refuses a target past the end of the device"
fi

# ------------------------------------- negative: half-grown (no publish)
log "building a half-grown image (tables written, superblock not published)"
CETRAFS_GROWFS_TEST_NO_PUBLISH=1 ct_growfs "$DEV" >/dev/null 2>&1
if out="$(ct_fsck "$DEV" 2>&1)"; then
    pass "a half-grown image reads clean at the OLD size, not as damage"
else
    fail "fsck called a half-grown image damaged: $out"
fi
if ct_mount "$DEV" "$MNT" 2>/dev/null; then
    size_half="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
    [ "$size_half" = "$size_before" ] &&
        pass "half-grown volume still reports the OLD capacity ($size_half bytes)" ||
        fail "half-grown volume changed size without a publish: $size_before -> $size_half" 
    ( cd "$MNT" && md5sum -c --quiet "$WORK/digests" ) &&
        pass "half-grown volume still reads every original file" ||
        fail "half-grown volume lost data"
    ct_umount "$MNT"
else
    fail "half-grown volume would not mount -- a crash mid-grow must leave the old fs intact"
fi

# -------------------------------------------------------------- the grow
log "growing to the full device"
if out="$(ct_growfs "$DEV" 2>&1)"; then
    pass "growfs completed"
else
    fail "growfs failed: $out"
fi
printf '%s\n' "$out" | grep -qE 'Block Groups: +[0-9]+ -> [0-9]+' &&
    pass "growfs reported the new Block Group count" ||
    fail "growfs printed no Block Group change"

log "fsck after the grow"
if out="$(ct_fsck "$DEV" 2>&1)"; then
    pass "grown volume is clean"
else
    fail "grown volume is not clean: $out"
fi
leaked_after="$(printf '%s' "$out" | grep -oE '[0-9]+ leaked' | grep -oE '^[0-9]+' || echo 0)"
[ "$leaked_after" = "$leaked_before" ] &&
    pass "the grow leaked no blocks (${leaked_before} before, ${leaked_after} after)" ||
    fail "the grow leaked blocks: ${leaked_before} before, ${leaked_after} after"

# A volume this build formatted is already at the current version, so
# the grow leaves it there. The 8 -> 9 transition is covered by
# growfs_compat.sh, which formats with the previous release.
POKE="$(ct_helper sb_poke)"
VDUMP="$(ct_tmp growfsver)"
"$POKE" "$DEV" > "$VDUMP" 2>/dev/null || true
gv="$(sed -n 's/^version=//p' "$VDUMP" | head -1)"
[ "$gv" = "9" ] && pass "the grown volume carries the current format version ($gv)" ||
    fail "the grown volume carries format version '$gv', expected 9"

# ------------------------------------------------- negative: already full
if out="$(ct_growfs "$DEV" 2>&1)" && grep -qi 'nothing to do' <<<"$out"; then
    pass "a second grow is a no-op, not an error"
else
    fail "growing an already-full-size volume did not report 'nothing to do': $out"
fi

# ------------------------------------------------- REPEATED GROWS
#
# A LUN gets extended more than once over its life, so one grow per
# volume is not a feature, it is a defect. The hard part is that each
# grow parks its relocated tables in a reserve immediately after the
# Block Groups -- so the NEXT grow's new BGs must step OVER that
# reserve, which leaves a hole in the data area and makes
# bg_regions_start + bg_cnt*bg_size_blocks false. Four separate places
# assumed that span was exact (one in the kernel validator, three in
# fsck); bg_data_end is what replaced it.
#
# Grow 1 is contiguous and proves nothing about any of this. Grow 2 is
# the first with a hole. Grows 3 and 4 are what say the hole handling
# repeats -- and accumulates, since each one must step over a reserve
# that is itself larger than the last (more ZGs and BGs to describe).
#
# Every round re-verifies EVERY file written in every previous round,
# so a grow that damages data laid down two grows ago still has to get
# past this.
log "four successive grows, verifying all prior data at every step"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
r=0
while dd if=/dev/urandom of="$MNT/m0_$r" bs=1M count=16 status=none 2>/dev/null; do
    r=$((r + 1))
    [ "$r" -gt 200 ] && break
done
sync
prev_size="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
( cd "$MNT" && md5sum m0_* > "$WORK/multi" )   # from disk -- see the note above
ct_umount "$MNT"

multi_ok=1
for round in 1 2 3 4; do
    case "$round" in
        1) tgt=1150M ;;
        2) tgt=1700M ;;
        3) tgt=2250M ;;
        4) tgt=2800M ;;
    esac

    if ! out="$(ct_growfs "$DEV" -s "$tgt" 2>&1)"; then
        fail "grow $round (to $tgt) failed: $out"
        multi_ok=0
        break
    fi
    if ! ct_fsck "$DEV" >/dev/null 2>&1; then
        fail "grow $round left the volume unclean"
        multi_ok=0
        break
    fi
    if ! ct_mount "$DEV" "$MNT" 2>/dev/null; then
        fail "grow $round produced a volume that will not mount"
        multi_ok=0
        break
    fi

    size_now="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
    [ "$size_now" -gt "$prev_size" ] ||
        { fail "grow $round did not add capacity: $prev_size -> $size_now"; multi_ok=0; }
    prev_size="$size_now"

    ( cd "$MNT" && md5sum -c --quiet "$WORK/multi" ) ||
        { fail "grow $round corrupted data written before it"; multi_ok=0; ct_umount "$MNT"; break; }

    w=0
    while dd if=/dev/urandom of="$MNT/m${round}_$w" bs=1M count=16 status=none 2>/dev/null; do
        w=$((w + 1))
        [ "$w" -gt 200 ] && break
    done
    sync
    [ "$w" -gt 4 ] || { fail "grow $round added capacity that took only $w files"; multi_ok=0; }
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    ( cd "$MNT" && md5sum "m${round}"_* >> "$WORK/multi" )   # from disk
    ( cd "$MNT" && md5sum -c --quiet "$WORK/multi" ) ||
        { fail "filling the space added by grow $round corrupted earlier data"; multi_ok=0; }
    ct_umount "$MNT"
done
[ "$multi_ok" = "1" ] &&
    pass "four successive grows, $(wc -l < "$WORK/multi") files verified across all of them" ||
    log "see the failures above"

# Each grow must have stranded its predecessor's reserve and said so,
# rather than quietly losing the space.
if out="$(ct_growfs "$DEV" -n 2>&1)" && grep -qE 'total ever: [1-9][0-9]* blocks' <<<"$out"; then
    pass "orphaned space is reported, not hidden"
else
    fail "growfs does not report accumulated orphaned blocks: $out"
fi

# Restore the fully-grown volume the payoff section expects.
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
i=0
while dd if=/dev/urandom of="$MNT/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 200 ] && break
done
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
( cd "$MNT" && md5sum f* > "$WORK/digests" )   # from disk
nfiles="$(wc -l < "$WORK/digests")"
ct_umount "$MNT"
ct_growfs "$DEV" >/dev/null 2>&1 || fail "re-grow for the payoff section failed"

# ---------------------------------------------------------- the payoff
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

size_after="$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')"
# TOTAL capacity, never free space: this assertion first compared `avail`
# on an empty volume against `avail` on a full one, which are unrelated
# numbers -- it reported +4096 bytes on a volume that had just doubled,
# and would have passed had the grow published nothing at all.
if [ "$size_after" -ge $((size_before * 15 / 10)) ]; then
    pass "capacity grew by at least half again ($size_before -> $size_after bytes)"
else
    fail "capacity did not grow as expected: $size_before -> $size_after bytes"
fi

log "verify #2: originals, after the grow, before anything is written"
( cd "$MNT" && md5sum -c --quiet "$WORK/digests" ) &&
    pass "all $nfiles originals verify after the grow" ||
    fail "originals corrupted by the grow itself"

log "writing into the NEW space"
j=0
while dd if=/dev/urandom of="$MNT/g$j" bs=1M count=16 status=none 2>/dev/null; do
    j=$((j + 1))
    [ "$j" -gt 200 ] && break
done
sync
[ "$j" -gt 4 ] && pass "wrote $j files into the grown space" ||
    fail "the grown space took only $j files -- it is not usable"

log "verify #3: originals, after the new space has been written"
( cd "$MNT" && md5sum -c --quiet "$WORK/digests" ) &&
    pass "all $nfiles originals still verify after the new space was written" ||
    fail "writing the new space corrupted the originals -- the new BGs overlap the old"

# The new Zone Group must have been CLAIMED and allocated from, not
# merely present: a grow that published capacity nothing can reach would
# pass every assertion above except this one.
if info="$(cat "/proc/fs/cetrafs/$(basename "$DEV")/info" 2>/dev/null)"; then
    # Growing no longer ADDS Zone Groups -- the added Block Groups are
    # spread across the ones that already exist, which is what gets the
    # new capacity to every node at once instead of to whoever claims a
    # new group (docs/internal/BG-OWNERSHIP-DESIGN.md). So what has to
    # be true is that the existing Zone Groups gained members.
    zgs="$(printf '%s' "$info" | grep -cE '^ *zg [0-9]+:' || true)"
    members="$(printf '%s' "$info" | grep -oE 'block_groups=[0-9]+' | grep -oE '[0-9]+' |
        awk '{t += $1} END {print t+0}')"
    [ "${members:-0}" -gt 1 ] &&
        pass "the $zgs Zone Group(s) hold $members Block Groups between them after the grow" ||
        fail "the Zone Groups hold ${members:-0} Block Group(s) after the grow"
    grep -qE '^ *zg [0-9]+:.*this node' <<<"$info" &&
        pass "a Zone Group is owned and allocated from" ||
        fail "no Zone Group is owned after the grow"
else
    skip "procfs info unavailable -- cannot confirm the new ZG was claimed"
fi

ct_umount "$MNT"
if out="$(ct_fsck "$DEV" 2>&1)"; then
    pass "grown-and-filled volume is clean"
else
    fail "grown-and-filled volume is not clean: $out"
fi

# ------------------------------------------- does verify #3 discriminate?
#
# Everything above passes against correct code, which says nothing about
# whether verify #3 would NOTICE the bug it exists for. Two separate
# misplacements get injected, because they are caught in two different
# places and only one of them reaches verify #3.
#
# (a) CETRAFS_GROWFS_TEST_BG_OFFSET moves the whole carve down one BG.
#     cetrafs_validate_layout() models the BG regions as a single
#     contiguous span, so a moved carve collides with the tail reserve
#     and the volume is refused AT MOUNT -- verify #3 is never reached.
#     Worth asserting anyway: it is the cheap check that catches the
#     likeliest arithmetic slip before a single block is written.
#
# (b) CETRAFS_GROWFS_TEST_DESC_SHIFT lies only in the new BG
#     DESCRIPTORS, leaving the published geometry correct, so the volume
#     mounts and fscks clean.
#
# MEASURED RESULT, recorded here rather than implied (tests/README.md:
# an assertion whose discriminating power you have not measured is a
# guess). Neither injection reaches verify #3:
#
#   (a) is refused at mount by cetrafs_validate_layout().
#   (b) makes the grown space UNUSABLE rather than corrupting: a BG's
#       data bitmap lives inside the region its descriptor names, so a
#       descriptor pointing at the old BG reads the old BG's full
#       bitmap and the allocator returns ENOSPC before writing a byte.
#
# So verify #3 is, as of this writing, an UNMEASURED backstop. It is
# kept because it covers the class "writing the new space damages the
# old" at nearly zero cost, and because both controls above prove the
# class is currently caught EARLIER rather than not at all -- but no
# injection has yet made verify #3 itself fire, and nobody should read
# its green line as evidence that it would.
prepare_filled_volume() {
    ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    local n=0
    while dd if=/dev/urandom of="$MNT/f$n" bs=1M count=16 status=none 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -gt 200 ] && break
    done
    sync
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    ( cd "$MNT" && md5sum f* > "$1" )   # from disk
    ct_umount "$MNT"
}

log "discrimination (a): the whole carve placed one BG too low"
prepare_filled_volume "$WORK/digests2"
CETRAFS_GROWFS_TEST_BG_OFFSET=-1 ct_growfs "$DEV" >/dev/null 2>&1 || true
if ct_mount "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"
    fail "a carve placed one BG too low mounted anyway -- the layout validator did not catch it"
else
    pass "a carve placed one BG too low is refused at mount"
fi

log "discrimination (b): correct geometry, lying BG descriptors"
prepare_filled_volume "$WORK/digests3"
CETRAFS_GROWFS_TEST_DESC_SHIFT=-1 ct_growfs "$DEV" >/dev/null 2>&1 || true

# A shifted descriptor now ALIASES an existing region rather than
# overlapping a different one, because the added Block Groups belong to
# Zone Groups that already exist. A Block Group's bitmap lives inside
# the region its descriptor names, so two descriptors pointing at one
# region share one bitmap and allocation stays self-consistent -- there
# is no corruption to find at runtime, which is why the old form of this
# check stopped firing when stage 2 landed.
#
# fsck is what catches it: two descriptors naming the same start block
# is exactly the ordered-and-non-overlapping rule it enforces.
if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "fsck called an image with two Block Group descriptors on one region clean"
else
    pass "fsck rejects aliased Block Group descriptors"
fi
# Captured first, THEN matched. `ct_fsck ... | grep -q` looks right and
# is not: under `set -o pipefail` the pipeline inherits fsck's exit
# status, and fsck exits non-zero here BY DESIGN -- so the test reported
# "unexpected reason" while printing the expected reason. Same trap as
# fsck_negative_controls' run_fsck.
fsck_out="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -q 'overlaps the previous Block Group' <<<"$fsck_out"; then
    pass "...and names the reason, rather than failing for some other one"
else
    fail "fsck rejected it for an unexpected reason: $(printf '%s' "$fsck_out" | grep -m1 ERR)"
fi

ct_exit
