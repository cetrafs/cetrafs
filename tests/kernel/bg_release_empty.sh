#!/usr/bin/env bash
# a node hands back the Block Groups it has emptied, instead of sitting on them
#
# STAGE 4 of docs/internal/BG-OWNERSHIP-DESIGN.md, and the reason the
# whole migration is worth doing.
#
# cetrafs_zg_release_surplus() already gives back a Zone Group that has
# gone entirely empty. The test it applies is all-or-nothing: a node
# holding a Zone Group with a hundred Block Groups, two of which still
# have data, gives back NOTHING and sits on ninety-eight empty ones
# forever while its peers see a full volume. That is a real bug today,
# not a hypothetical.
#
# Per-Block-Group ownership lets the same rule apply one level down:
# hand back the empty ones, keep the two that are not.
#
# THE RULE DOES NOT CHANGE, and must not: only ever give back what is
# provably empty. Releasing is the dangerous direction. A wrong CLAIM
# costs a failed compare-and-swap; a wrong RELEASE hands live data to
# somebody else, who allocates over it. The existing code says exactly
# this and sidesteps the question by only releasing what has no live
# data at all; so does this.
#
# The local hazard the finer granularity introduces: the node keeps the
# Zone Group and keeps allocating from it, so its OWN allocator could
# take a block in the gap between "I checked this one is empty" and "I
# handed it back". That is same-node, so it needs no cross-node
# machinery -- the Block Group is marked draining under the allocation
# lock first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 1800 bgrel)"
MNT="$(ct_mnt bgrel)"

# One Zone Group owning three Block Groups: fill all three, then delete
# the data from two of them. The hoarding case in miniature.
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
owned="$(ct_bgs_of_zg "$DEV" 0 | wc -l)"
[ "$owned" -ge 2 ] && pass "Zone Group 0 owns $owned Block Groups to start with" ||
    { fail "only $owned Block Group(s) -- this suite needs several"; ct_exit; }

# The release pass runs on the heartbeat tick. At the production 15s tick
# the 30s waits below are barely two ticks, so a tick slipping under load
# (seen failing once inside a full `make check`) reads as "handed back
# nothing". Compress the tick to 1s -- what is under test is that a tick
# releases an emptied Block Group, not how long a tick takes. Restored at
# ct_exit (the param is module-global).
compress_timing

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# The bulk goes in a SUBDIRECTORY that is removed whole.
#
# A directory never gives blocks back on unlink, and the root's dirent
# blocks are allocated as entries are added -- so filling the root with
# a hundred files scatters root dirent blocks across every Block Group,
# and not one of them can ever read empty again however much data is
# deleted. The suite then blamed the release for refusing to hand back
# Block Groups that genuinely still held live metadata; fsck agreed with
# the kernel ("12296 data blocks referenced", matching the counters
# exactly). Removing the directory itself frees those blocks.
log "filling every Block Group, then emptying all but one"
mkdir -p "$MNT/bulk"
i=0
while dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 300 ] && break
done
sync
[ "$i" -gt 8 ] && pass "filled the volume with $i files" || fail "only $i files written"

# Keep the first few, delete the rest: most Block Groups go empty, at
# least one keeps live data.
keep=3
# Free the bulk FIRST -- the volume is full, so nothing else can be
# written until it is -- then write the files to keep. `rm -rf` takes
# the directory's own dirent blocks with it, which is the point: those
# are what used to keep every Block Group permanently non-empty.
rm -rf "$MNT/bulk"
sync
j=0
while [ "$j" -lt "$keep" ]; do
    dd if=/dev/urandom of="$MNT/keep$j" bs=1M count=4 status=none || break
    j=$((j + 1))
done
sync
sync
pass "deleted the bulk directory ($i files) whole, keeping $keep files in the root"

# statfs, before any Block Group is handed back. A released BG belongs
# to no Zone Group, and statfs sums the ZG aggregates -- so without the
# sharded pool (cetrafs_zone_group_t.pool_free_blocks) every hand-back
# silently shrank df by the group's whole capacity (~512 MiB). Caught by
# the cross-node xattrs scenario on a three-node run, 2026-10-28: free
# space read 5.5M blocks short -- 42 released groups -- while every
# node's internal counter agreed on the true figure.
read -r PRE_FREE PRE_BSZ <<<"$(stat -f -c '%f %S' "$MNT")"
PRE_FREE_4K=$((PRE_FREE * PRE_BSZ / 4096))

# The heartbeat's release pass is what gives them back. Wait for it
# rather than assuming one tick has gone by.
if wait_for 30 '[ "$(ct_bgs_of_zg "'"$DEV"'" 65535 2>/dev/null | wc -l)" -gt 0 ]' 2>/dev/null; then
    pass "a Block Group was handed back while the node kept running"

    # df must NOT have shrunk by the released capacity: the pool shard
    # keeps the handed-back blocks counted. Tolerance covers unrelated
    # metadata churn between the two reads; the bug loses ~131072 blocks
    # per released group, two orders of magnitude past it.
    read -r POST_FREE POST_BSZ <<<"$(stat -f -c '%f %S' "$MNT")"
    POST_FREE_4K=$((POST_FREE * POST_BSZ / 4096))
    if [ "$POST_FREE_4K" -ge $((PRE_FREE_4K - 1024)) ]; then
        pass "statfs kept the released capacity (free $PRE_FREE_4K -> $POST_FREE_4K blocks)"
    else
        fail "statfs LOST the released capacity: free $PRE_FREE_4K -> $POST_FREE_4K blocks -- unowned BGs are counted nowhere"
    fi
else
    log "note: nothing handed back yet from the mounted node"
fi

ct_umount "$MNT"

freed="$("$MAP" "$DEV" | awk -v f="$FREE_MARK" '/^bg /{split($3,a,"="); if (a[2]+0 == f+0) n++} END{print n+0}')"
still="$(ct_bgs_of_zg "$DEV" 0 | wc -l)"
[ "$freed" -gt 0 ] &&
    pass "$freed Block Group(s) handed back, $still still owned" ||
    fail "the node emptied $((i - keep)) files' worth of space and handed back nothing"

# The ones it kept must still hold the data it kept.
ct_mount "$DEV" "$MNT"
kept_ok=1
k=0
while [ "$k" -lt "$keep" ]; do
    [ -s "$MNT/keep$k" ] || kept_ok=0
    k=$((k + 1))
done
[ "$kept_ok" = "1" ] && pass "the files it kept are still readable" ||
    fail "handing back empty Block Groups lost data that was still live"
ct_umount "$MNT"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean after the release" ||
    fail "not clean after the release: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"

# ------------------------------------- a Block Group with data is NEVER given back
log "a Block Group holding live data is never handed back"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
dd if=/dev/urandom of="$MNT/keep" bs=1M count=64 status=none
sync
sleep 3
ct_umount "$MNT"
held="$("$MAP" "$DEV" | awk '/^bg 0 /{split($3,a,"="); print a[2]}')"
[ "$held" != "$FREE_MARK" ] &&
    pass "the Block Group holding the file is still owned (ZG $held)" ||
    fail "a Block Group with live data in it was handed back"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean" || fail "not clean"

# ----------------------- is the emptiness check what prevents the loss?
#
# Everything above passes against correct code, which says nothing about
# WHY a Block Group with data in it stayed owned. Forcing the release to
# skip its emptiness check must now hand that Block Group back -- and
# once it is free, the space holding live data is somebody else's to
# allocate. If it stays owned anyway, the check above proves nothing and
# something else is doing the work.
if [ -w /sys/module/cetrafs/parameters/bg_release_skip_empty_check ]; then
    log "discrimination: release with the emptiness check removed"
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/live" bs=1M count=64 status=none
    sync
    ct_param_set bg_release_skip_empty_check 1
    # Poll for the heartbeat's release pass rather than sleeping a
    # guess. A fixed 6s was too short -- the suite's own positive case
    # uses wait_for 30 for the same tick -- so the control "failed"
    # because nothing had run yet, not because the check was doing
    # nothing. A negative control that fires late reads exactly like
    # one that does not fire.
    wait_for 40 '[ "$('"$MAP"' '"$DEV"' | awk -v f='"$FREE_MARK"' "/^bg /{split(\$3,a,\"=\"); if (a[2]+0 == f+0) n++} END{print n+0}")" -gt 0 ]' || true
    ct_param_set bg_release_skip_empty_check 0
    ct_umount "$MNT"

    gone="$("$MAP" "$DEV" | awk -v f="$FREE_MARK" '/^bg /{split($3,a,"="); if (a[2]+0 == f+0) n++} END{print n+0}')"
    if [ "$gone" -gt 0 ]; then
        pass "without the emptiness check, $gone Block Group(s) holding live data were handed back -- the check is what prevents it"
    else
        fail "even with the emptiness check removed nothing was released -- the check is not what keeps live data safe, something else is"
    fi
else
    skip "bg_release_skip_empty_check unavailable -- cannot measure what the emptiness check contributes"
fi

ct_exit