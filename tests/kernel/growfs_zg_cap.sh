#!/usr/bin/env bash
# growing a volume that already has the maximum 255 Zone Groups needs no special case
#
# Zone Groups are capped at 255 (CETRAFS_MAX_ZONE_GROUPS) because
# ownership is tracked in fixed-size per-mount bitmaps. Growing used to
# add Zone Groups in proportion to the Block Groups it added, so the cap
# was a real constraint with its own branch: at 255 the added Block
# Groups were folded into the LAST Zone Group, because a Zone Group
# owned a contiguous range and only the last one could be extended.
# That handed every new byte to whichever node owned the tail.
#
# Per-Block-Group ownership removes both the branch and the problem: a
# grow spreads the new Block Groups across the Zone Groups that already
# exist, so the count never changes and the cap is never reached by
# growing (docs/internal/BG-OWNERSHIP-DESIGN.md).
#
# This suite asserts that absence of a special case. At the cap, a grow
# must behave exactly as anywhere else: Zone Group count unchanged,
# Block Group count up, the new capacity SPREAD rather than piled onto
# one group, data intact, fsck clean.
#
# "Spread" is measured as the number of Zone Groups whose block_groups
# count RISES across the grow (procfs, before and after). A volume at
# the cap already has ~25 groups with two Block Groups each, so a count
# of groups holding more than one would pass before any grow happened.
#
# DISCRIMINATION: CETRAFS_GROWFS_TEST_FOLD_LAST folds every new Block
# Group onto the last Zone Group, the old behaviour. The control runs a
# second cap volume that way and requires the same measurement to see
# exactly one group gain capacity.
#
# Reaching 255 Zone Groups needs more than 127 GiB of nominal capacity
# (255 x one 512 MiB Block Group, at minimum), so this builds a
# nominally huge SPARSE device and never writes bulk data to it: mkfs
# and the grow together touch only the tables and each Block Group's
# header and bitmap.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

MAX_ZG=255

DEV="$(ct_sparse_dev 200000 growzgcap)"
MNT="$(ct_mnt growzgcap)"
POKE="$(ct_helper sb_poke)"
DUMP="$(ct_tmp growzgcapdump)"
ct_track file "$DUMP.dig"

sbval() { sed -n "s/^$1=//p" "$DUMP" | head -1; }

# zg_members <device>: "zg-number block-group-count" for each Zone Group,
# read from procfs. Needs the volume mounted, and then it is.
zg_members() {
    local info
    info="$(cat "/proc/fs/cetrafs/$(basename "$1")/info")"
    awk '/^  zg [0-9]+:/ { z = $2; sub(":", "", z) }
         /block_groups=/ { n = $0; sub(/.*block_groups=/, "", n); sub(/ .*/, "", n); print z, n }' <<<"$info"
}

# gained <before-file> <after-file>: how many Zone Groups have MORE Block
# Groups after the grow than before.
gained() {
    awk 'NR == FNR { b[$1] = $2; next } ($2 + 0 > b[$1] + 0) { n++ } END { print n + 0 }' "$1" "$2"
}

log "formatting 140 GiB of a 200 GiB device with the maximum $MAX_ZG Zone Groups"
if out="$(ct_mkfs "$DEV" -s 140G -b 512 -z "$MAX_ZG" -J 0 -N 4096 -f 2>&1)"; then
    pass "mkfs at the Zone Group cap succeeded"
else
    fail "mkfs failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    ct_exit
fi

"$POKE" "$DEV" > "$DUMP" 2>/dev/null || true
zg_before="$(sbval zone_group_count)"
bg_before="$(sbval block_group_count)"
[ "$zg_before" = "$MAX_ZG" ] && pass "volume starts at the $MAX_ZG Zone Group cap" ||
    { fail "volume has $zg_before Zone Groups, not the cap -- the fold branch will not be reached"; ct_exit; }

ct_fsck "$DEV" >/dev/null 2>&1 && pass "capped volume is clean" || fail "capped volume is not clean"

# A little real data, so the grow has something to preserve. Deliberately
# small: this device must never be filled (see ct_sparse_dev).
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir -p "$MNT/d"
for i in 0 1 2 3 4 5 6 7; do
    dd if=/dev/urandom of="$MNT/d/f$i" bs=1M count=4 status=none
done
sync
( cd "$MNT" && md5sum d/* > /dev/null ) && ( cd "$MNT" && md5sum d/* > "$DUMP.dig" )
zg_members "$DEV" > "$DUMP.zg.before"
ct_umount "$MNT"

log "growing to the full device, with no room for new Zone Groups"
if out="$(ct_growfs "$DEV" 2>&1)"; then
    pass "growfs completed at the Zone Group cap"
else
    fail "growfs failed at the cap: $out"
    ct_exit
fi
grep -qE "Zone Groups: +$MAX_ZG -> $MAX_ZG" <<<"$out" &&
    pass "growfs reported the Zone Group count staying at the cap" ||
    fail "growfs did not keep the Zone Group count at the cap: $(printf '%s' "$out" | grep -i 'Zone Groups')"

"$POKE" "$DEV" > "$DUMP" 2>/dev/null || true
zg_after="$(sbval zone_group_count)"
bg_after="$(sbval block_group_count)"
[ "$zg_after" = "$MAX_ZG" ] && pass "superblock still reports $MAX_ZG Zone Groups" ||
    fail "Zone Group count moved past the cap: $zg_before -> $zg_after"
[ "$bg_after" -gt "$bg_before" ] && pass "Block Group count grew ($bg_before -> $bg_after)" ||
    fail "no Block Groups were added: $bg_before -> $bg_after"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "grown capped volume is clean" ||
    fail "grown capped volume is not clean"

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
( cd "$MNT" && md5sum -c --quiet "$DUMP.dig" ) && pass "data survived the capped grow" ||
    fail "data did not survive the capped grow"

# The added Block Groups must be SPREAD: the number of Zone Groups that
# gained one, and the total they gained, must account for the growth.
zg_members "$DEV" > "$DUMP.zg.after"
G="$(gained "$DUMP.zg.before" "$DUMP.zg.after")"
added="$(awk 'NR == FNR { b += $2; next } { a += $2 } END { print a - b }' "$DUMP.zg.before" "$DUMP.zg.after")"
if [ "$added" = "$((bg_after - bg_before))" ] && [ "$G" -gt 1 ]; then
    pass "the $added added Block Groups were spread across $G Zone Groups, not folded into one"
else
    fail "the capacity was not spread: $G Zone Group(s) gained $added Block Group(s) (expected $((bg_after - bg_before)) in more than one group)"
fi

# And the new space has to be usable, not merely counted.
dd if=/dev/urandom of="$MNT/after_grow" bs=1M count=8 status=none &&
    pass "the capped volume accepts writes after the grow" ||
    fail "the capped volume will not take a write after the grow"
sync
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean at the end" || fail "not clean at the end"

# ---- the control: the same measurement must see a fold
#
# A second cap volume, grown with the old fold behaviour switched on. If
# the gain count does not come out as exactly one, the measurement above
# cannot tell a spread from a pile and the spread assertion proves
# nothing.
FOLD_DEV="$(ct_sparse_dev 200000 growzgfold)"
if out="$(ct_mkfs "$FOLD_DEV" -s 140G -b 512 -z "$MAX_ZG" -J 0 -N 4096 -f 2>&1)"; then
    ct_mount "$FOLD_DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    zg_members "$FOLD_DEV" > "$DUMP.fold.before"
    ct_umount "$MNT"
    if out="$(CETRAFS_GROWFS_TEST_FOLD_LAST=1 ct_growfs "$FOLD_DEV" 2>&1)"; then
        ct_mount "$FOLD_DEV" "$MNT"
        require_cetrafs_mount "$MNT"
        zg_members "$FOLD_DEV" > "$DUMP.fold.after"
        ct_umount "$MNT"
        FG="$(gained "$DUMP.fold.before" "$DUMP.fold.after")"
        if [ "$FG" = 1 ]; then
            pass "control: a grow that folds the Block Groups onto the last Zone Group is seen as one group gaining ($FG)"
        else
            fail "control: a folded grow reads as $FG Zone Groups gaining capacity -- the spread check does not discriminate"
        fi
    else
        fail "control: the folded grow failed: $(printf '%s' "$out" | tail -1)"
    fi
else
    fail "control: mkfs of the control volume failed: $(printf '%s' "$out" | tail -1)"
fi

ct_exit
