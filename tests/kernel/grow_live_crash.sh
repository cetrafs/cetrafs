#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow that dies between its writes leaves a volume that mounts at the old size and can be finished
#
# cetrafs_grow_commit() (kmod/grow.c) makes three writes, each a
# compare-and-swap: the pool shard credits, the old tail's link to the
# new segment, the superblock. grow_stop_after abandons the grow after
# the first or the second, returning -EIO as a node dying there would
# leave it. What each must leave, as the code's comment states it:
#
#  1. credits only: the old volume, intact and writable; the pool
#     OVERSTATES free space by what the grow would have added, and each
#     shard NAMES that credit (pool_grow_gen/id/credit). fsck reports
#     the shard and the dead credit and nothing else. Then each of the
#     three ways the credit comes back out:
#       1  the next MOUNT takes it back (control: grow_heal_off=1 and
#          the mount leaves it; fsck still reports it);
#       1b a re-run of the grow replaces it rather than stacking a
#          second credit on it -- fsck clean after the finished grow;
#       1c fsck -r recounts the pool AND clears the marker, so the
#          mount after it does not take the credit back a second time.
#  2. credits and link: the chain is one segment past the count. Mount
#     and fsck accept it at the OLD size and say so (it is what every
#     node sees between a live grow's last two writes); running growfs
#     again finishes the grow.
#
#  3. an OFFLINE grow after a stopped live grow takes the dead credit
#     back before it publishes (control: CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT,
#     and fsck finds the pool overstated).
#
# DISCRIMINATION: with the mount's heal off throughout (grow_heal_off),
# 1 fails; with step 1 crediting without replacing a dead credit, 1b's
# fsck reports the pool overstated; with fsck -r leaving the marker,
# 1c's mount takes the credit back again (2026-11-12).
#
# And a segment linked past the count that is NOT a grow's next segment
# is still refused, by the mount and by fsck: acceptance is exactly as
# wide as the state a grow leaves, not "anything after the count".
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SEG="$(ct_helper seg_poke)"

DEV="$(ct_big_dev 2900 growcrash)"
MNT="$(ct_mnt growcrash)"
WORK="$(ct_mnt growcrashwork)"
ct_track mnt "$MNT"
ct_param_set grow_stop_after 0
ct_param_set grow_heal_off 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
sb_sum() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | md5sum; }
verify() {
    sync; echo 3 >/proc/sys/vm/drop_caches
    (cd "$MNT" && md5sum -c --quiet "$WORK/digests") && pass "$1: the data reads back intact" ||
        fail "$1: data written before the grow no longer reads back"
}
only_pool_errs() { # fsck output -> 0 if every ERR is about a pool shard
    local errs; errs="$(grep ERR <<<"$1" || true)"
    [ -n "$errs" ] && ! grep -v -e 'pool_free_blocks' -e 'pool credit' <<<"$errs" | grep -q .
}

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for i in 0 1 2 3; do dd if=/dev/urandom of="$MNT/d$i" bs=1M count=8 conv=fsync status=none; done
(cd "$MNT" && md5sum d* >"$WORK/digests")
out="$(ct_growfs "$DEV" -s 1400M 2>&1)" ||
    { fail "setup: the first live grow failed: $(tail -2 <<<"$out")"; ct_exit; }
pass "setup: a first live grow (later grows then link from a tail segment)"

# --------------------------------------------------- 1: credits, no link
stopped() { # <n> <tag> <size>
    local gen0 sum0 out
    gen0="$(info layout_gen)"; sum0="$(sb_sum)"
    ct_param_set grow_stop_after "$1"
    if out="$(ct_growfs "$DEV" -s "$3" 2>&1)"; then
        fail "$2: setup: the grow completed although it was told to stop after write $1"
        return 1
    fi
    [ "$(cat /sys/module/cetrafs/parameters/grow_stop_after)" = 0 ] ||
        { fail "$2: setup: the grow never reached its commit (stop_after not consumed): $(tail -1 <<<"$out")"; return 1; }
    pass "$2: setup: the grow stopped after write $1"
    [ "$(sb_sum)" = "$sum0" ] && [ "$(info layout_gen)" = "$gen0" ] &&
        pass "$2: the superblock and this node's layout are unchanged" ||
        fail "$2: a grow that never published changed the superblock or the layout"
    echo after >"$MNT/after-$1" && sync && pass "$2: the volume is still writable" ||
        fail "$2: the volume stopped taking writes"
}

dead_credit() { # <tag>: fsck (offline) reports the dead credit and nothing but the pool
    local out
    out="$(ct_fsck "$DEV" 2>&1)" && { fail "$1: fsck is clean -- the credits never reached the pool (setup)"; return; }
    grep -q 'never published' <<<"$out" || { fail "$1: fsck does not name the dead grow's credit"; return; }
    only_pool_errs "$out" && pass "$1: fsck reports the overstated pool and the dead grow's credit, nothing else" ||
        fail "$1: fsck reports more than the pool: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
}
clean() { # <tag> <what>
    local out
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: $2" ||
        fail "$1: not clean: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
}

log "1: a grow stopped after its pool credits; the next mount takes them back"
stopped 1 "credits" 2100M || ct_exit
verify "credits"
ct_umount "$MNT"
dead_credit "credits"
ct_param_set grow_heal_off 1
ct_mount "$DEV" "$MNT"; ct_umount "$MNT"
ct_param_set grow_heal_off 0
dead_credit "credits: control (the mount's heal off)"
mark="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$mark" | grep -q 'live grow that never published -- taken back' &&
    pass "credits: the mount says it took the dead grow's credit back" ||
    fail "credits: the mount said nothing about the dead grow's credit"
ct_umount "$MNT"
clean "credits" "after a mount, fsck is clean with no -r"
ct_mount "$DEV" "$MNT"

log "1b: a grow stopped after its credits, then run again to the end"
stopped 1 "re-run" 2100M || ct_exit
out="$(ct_growfs "$DEV" -s 2100M 2>&1)" && pass "re-run: the grow completed live the second time" ||
    { fail "re-run: the second grow failed: $(tail -2 <<<"$out")"; ct_exit; }
verify "re-run"
ct_umount "$MNT"
clean "re-run" "fsck is clean: the re-run replaced the dead credit, it did not add a second"
ct_mount "$DEV" "$MNT"

log "1c: fsck -r recounts a dead credit, and the next mount does not take it again"
stopped 1 "repair" 2800M || ct_exit
ct_umount "$MNT"
dead_credit "repair"
ct_fsck_repair "$DEV" >/dev/null 2>&1 || true
clean "repair" "fsck -r recounts the pool and clears the credit"
mark="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$mark" | grep -q 'never published -- taken back' &&
    fail "repair: the mount after fsck -r took a credit back again" ||
    pass "repair: the mount after fsck -r finds nothing to take back"
ct_umount "$MNT"
clean "repair" "and fsck is still clean after that mount"
ct_mount "$DEV" "$MNT"

# ------------------------------------------------- 2: credits and link
log "2: a grow stopped after linking its segment, before publishing"
stopped 2 "link" 2800M || ct_exit
ct_umount "$MNT"
mark="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    dmesg_since "$mark" | grep -q 'does not count yet' &&
        pass "link: the volume mounts at the old size and names the unpublished segment" ||
        fail "link: the volume mounted without the chain being one segment long -- the link never landed (setup)"
    verify "link, remounted"
    ct_umount "$MNT"
else
    fail "link: a grow stopped between its link and its publish left a volume that will not mount"
fi
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q 'does not count yet' <<<"$out" && pass "link: fsck names the unpublished segment" ||
    fail "link: fsck does not mention the unpublished segment"

log "2b: a segment past the count that is not a grow's next segment is still refused"
TAIL="$("$SEG" "$DEV" dump | sed -n 's/.*tail=\([0-9][0-9]*\).*/\1/p')"
[ -n "$TAIL" ] || { fail "2b: setup: no tail segment found"; ct_exit; }
dd if="$DEV" of="$WORK/pending" bs=4096 skip="$TAIL" count=1 iflag=direct status=none
"$SEG" "$DEV" dangle 5 >/dev/null # the pending segment now links on: not the end of a chain
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"; fail "2b: a pending segment that links further was accepted by the mount"
else
    pass "2b: the mount refuses a pending segment that is not the end of the chain"
fi
out="$(ct_fsck "$DEV" 2>&1)" && fail "2b: fsck accepts a pending segment that links further" ||
    pass "2b: so does fsck"
dd if="$WORK/pending" of="$DEV" bs=4096 seek="$TAIL" count=1 oflag=direct conv=notrunc status=none # back to what the stopped grow left

log "2c: running growfs again finishes the grow"
ct_mount "$DEV" "$MNT" # its mount at step 2 already took the stopped grow's credits back
gen0="$(info layout_gen)"; bgs0="$(info block_group_count)"
out="$(ct_growfs "$DEV" -s 2800M 2>&1)" && pass "2c: the re-run completed live" ||
    fail "2c: the re-run failed: $(tail -2 <<<"$out")"
[ "$(info layout_gen)" = "$((gen0 + 1))" ] && [ "$(info block_group_count)" -gt "$bgs0" ] &&
    pass "2c: the node is at layout_gen $((gen0 + 1)) with $(info block_group_count) Block Groups" ||
    fail "2c: the re-run did not move the layout"
verify "2c"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "2c: fsck is clean after the finished grow" ||
    fail "2c: fsck after the finished grow: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"

# ------------------------------------- 3: an OFFLINE grow after a dead one
# The operator's next step after a stopped live grow may be growfs on
# the unmounted volume rather than a mount. That grow publishes the
# layout_gen the dead marker names, after which the marker reads as
# settled and the dead credit stays in the pool for good (review of
# 63e7f0e). The offline grow takes it back before it publishes.
offline_after_dead() { # <tag> [env...]: fresh volume, a dead live grow, then an offline grow
    ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set grow_stop_after 1
    ct_growfs "$DEV" -s 1400M >/dev/null 2>&1 && { fail "$1: setup: the live grow did not stop"; return 1; }
    ct_umount "$MNT"
    dead_credit "$1: setup"
    shift
    out="$(env "$@" "$ROOT/userspace/growfs.cetra" "$DEV" -s 1400M 2>&1)" ||
        { fail "offline: the offline grow failed: $(tail -2 <<<"$out")"; return 1; }
}
log "3: an offline grow after a stopped live grow"
offline_after_dead "3 control" CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT=1 || ct_exit
out="$(ct_fsck "$DEV" 2>&1)" && fail "3 control: fsck is clean -- the suite cannot tell the two apart" ||
    { grep -q 'pool_free_blocks' <<<"$out" && pass "3 control: keeping the dead credit leaves the pool overstated" ||
        fail "3 control: fsck fails, but not on the pool: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"; }
offline_after_dead "3" || ct_exit
grep -q 'taking back the pool credit' <<<"$out" && pass "3: the offline grow says it took the dead credit back" ||
    fail "3: the offline grow said nothing about the dead credit"
clean "3" "fsck is clean after the offline grow, with no -r"
ct_exit
