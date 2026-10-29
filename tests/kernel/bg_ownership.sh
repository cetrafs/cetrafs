#!/usr/bin/env bash
# what Zone Group <-> Block Group ownership means today, pinned before it is changed
#
# STAGE 0 of docs/internal/BG-OWNERSHIP-DESIGN.md. No code change goes
# with this suite: it exists to state, in assertions, the behaviour that
# must survive a migration from "a Zone Group owns a fixed contiguous
# range of Block Groups" to "each Block Group records its own owner".
#
# Everything here is true of the CURRENT code and must stay true after
# every later stage -- with one deliberate exception, marked TEMPORARY
# below, which is the invariant being deliberately removed. That one is
# expected to be deleted at stage 2, by a commit that says so.
#
# The point of writing these first is that the dangerous part of the
# migration is not the new behaviour, it is silently losing some of the
# old. A refactor across the allocation path that keeps every one of
# these green is a refactor that did not quietly change what a node is
# allowed to write to.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

MAP="$(ct_helper bg_map)"
IMG="$(ct_image 1200 bgown)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgown)"
W="$(ct_mnt bgownwork)"

ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null

# ------------------------------------------------- the mapping on disk
"$MAP" "$DEV" > "$W/map0"
zg_count="$(awk '/^counts/ {print $2}' "$W/map0")"
bg_count="$(awk '/^counts/ {print $3}' "$W/map0")"
[ -n "$bg_count" ] && [ "$bg_count" -gt 0 ] &&
    pass "image has $zg_count Zone Group(s) and $bg_count Block Group(s)" ||
    { fail "could not read the mapping -- nothing below would mean anything"; ct_exit; }

# 1. Every Block Group names an owner, and that owner exists.
bad="$(awk -v zc="$zg_count" '/^bg /{split($3,a,"="); if (a[2]+0 >= zc+0) print $2}' "$W/map0")"
[ -z "$bad" ] && pass "every Block Group is owned by a Zone Group that exists" ||
    fail "Block Group(s) owned by a nonexistent Zone Group: $bad"

# 2. Exactly one owner each -- one line per Block Group, no duplicates,
#    and every id from 0..bg_count-1 present.
n_bg_lines="$(grep -c '^bg ' "$W/map0")"
n_uniq="$(awk '/^bg /{print $2}' "$W/map0" | sort -u | wc -l)"
[ "$n_bg_lines" = "$bg_count" ] && [ "$n_uniq" = "$bg_count" ] &&
    pass "each of the $bg_count Block Groups appears exactly once" ||
    fail "Block Group ids are not one-to-one: $n_bg_lines lines, $n_uniq distinct, expected $bg_count"

# 3. (was: the Zone Group ranges and the Block Group records describe
#     the same mapping -- deleted at stage 2, as it said it would be.
#     There is only one representation now: the Block Group's own
#     owner_zg. A Zone Group has no member list to disagree with.)

# 4. Every Zone Group named as an owner actually exists, and ownership
#    is spread rather than piled onto one Zone Group -- mkfs assigns
#    round-robin now, so a volume with more than one Zone Group must
#    have more than one owner represented. The old check here required
#    the Zone Group ranges to TILE the Block Group space exactly; that
#    was a property of contiguous spans, which are gone.
owners="$(awk '/^bg /{split($3,a,"="); print a[2]}' "$W/map0" | sort -u)"
n_owners="$(printf '%s\n' "$owners" | grep -c .)"
if [ "$zg_count" -gt 1 ] && [ "$bg_count" -ge "$zg_count" ]; then
    [ "$n_owners" -gt 1 ] &&
        pass "ownership is spread across $n_owners Zone Groups, not piled on one" ||
        fail "all $bg_count Block Groups name Zone Group $owners -- assignment is not spreading"
else
    pass "only $zg_count Zone Group(s) to spread across"
fi

# ------------------------------------- what a node may actually write to
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

owned_zgs="$(sed -n 's/^ *zg \([0-9]*\):.*this node.*/\1/p' "/proc/fs/cetrafs/$(basename "$DEV")/info" 2>/dev/null || true)"
[ -n "$owned_zgs" ] && pass "this node owns Zone Group(s): $(echo $owned_zgs | tr '\n' ' ')" ||
    { fail "the node owns no Zone Group -- it could not allocate at all"; ct_exit; }

dd if=/dev/urandom of="$MNT/data" bs=1M count=64 status=none
sync
ct_umount "$MNT"

# 5. Only Block Groups belonging to a Zone Group this node owns lost
#    free space. This is the rule the whole migration has to preserve:
#    a node writes only where it is allowed to.
"$MAP" "$DEV" > "$W/map1"
consumed=""
while read -r _ bid own _ free1; do
    bid_n="$bid"
    f0="$(awk -v b="$bid_n" '/^bg /{if ($2+0==b+0) print $5}' "$W/map0")"
    [ "$free1" != "$f0" ] && consumed="$consumed $bid_n:${own#owner_zg=}"
done < <(grep '^bg ' "$W/map1")

[ -n "$consumed" ] && pass "writing consumed space in Block Group(s):$consumed" ||
    fail "no Block Group changed -- the write did not allocate, so nothing below is tested"

trespass=""
for e in $consumed; do
    z="${e#*:}"
    echo "$owned_zgs" | grep -qx "$z" || trespass="$trespass $e"
done
[ -z "$trespass" ] &&
    pass "every Block Group written to belongs to a Zone Group this node owns" ||
    fail "this node allocated from Zone Group(s) it does not own:$trespass"

# 6. And it REFUSES when the Block Group is not its own. alloc_force_foreign
#    exists precisely so this path can be reached without a second node.
if [ -w /sys/module/cetrafs/parameters/alloc_force_foreign ]; then
    ct_mount "$DEV" "$MNT"
    # ct_param_set, not a raw echo: it records the prior value and the
    # harness restores it on EVERY exit path. A raw echo leaves the
    # parameter set if this suite dies between setting and clearing it,
    # which poisons every suite that runs afterwards.
    ct_param_set alloc_force_foreign 1
    if dd if=/dev/urandom of="$MNT/foreign" bs=1M count=4 status=none 2>/dev/null && sync 2>/dev/null; then
        ct_param_set alloc_force_foreign 0
        fail "allocation succeeded with every Block Group marked foreign"
    else
        ct_param_set alloc_force_foreign 0
        pass "a node refuses to allocate from a Block Group it does not own"
    fi
    rm -f "$MNT/foreign" 2>/dev/null || true
    ct_umount "$MNT"
else
    skip "alloc_force_foreign unavailable -- cannot test the refusal path"
fi

ct_fsck "$DEV" >/dev/null 2>&1 && pass "volume is clean" || fail "volume is not clean"

# ------------------------------------------- do these assertions FIRE?
#
# Everything above passes against a correct image, which proves nothing
# about whether it would notice damage. Both checks that the migration
# depends on are injected here and required to fail. Without this the
# suite is a description, not a test -- and a description cannot stop a
# refactor from quietly changing who may write where.
POKE="$(ct_helper bg_poke)"

log "discrimination: point a Block Group at a Zone Group that does not exist"
cp "$W/map0" "$W/mapsave"
"$POKE" "$DEV" 0 --owner 99 >/dev/null
"$MAP" "$DEV" > "$W/mapbad"
bad="$(awk -v zc="$zg_count" '/^bg /{split($3,a,"="); if (a[2]+0 >= zc+0) print $2}' "$W/mapbad")"
[ -n "$bad" ] && pass "a Block Group owned by a nonexistent Zone Group is detected" ||
    fail "a Block Group pointed at Zone Group 99 was not noticed -- check 1 proves nothing"

if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "fsck called an image with a Block Group owned by Zone Group 99 clean"
else
    pass "fsck also rejects it"
fi

# (The second discrimination case -- a Block Group pointed at a
# different VALID Zone Group -- went with the agreement check it
# existed to measure. With one representation there is nothing to
# disagree with: whatever owner_zg says IS the mapping. What can still
# be wrong is naming a Zone Group that does not exist, which the case
# above injects and fsck rejects.)

# Put it back so the final state is sane for anything reading the image.
"$POKE" "$DEV" 0 --owner 0 >/dev/null

ct_exit
