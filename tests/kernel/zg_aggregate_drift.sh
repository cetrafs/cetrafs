#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group aggregate neither drifts on a claim nor wedges the flush when it has
#
# A Zone Group's free_data_blocks aggregate is a cache of its Block
# Groups' counts, moved by accrued deltas at each durability boundary
# (audit 2026-11-06 M4). Three faults:
#
#   (1) A delta that would take the aggregate below zero was refused and
#       re-accrued, so every later flush failed the same way: sync_fs
#       returned an error for good, the flock suspend used by migration
#       failed, the surplus release never ran. Now dropped, as the Block
#       Group side already does. Staged: the aggregate poked to 0 under a
#       mounted volume, then a write.
#   (2) A Block Group claim made the group allocatable, then read its free
#       count to credit the aggregate. An allocation in between lowered
#       that count and accrued its own debit: counted twice. Staged:
#       bg_claim_stall_ms holds the claim there while a second writer
#       allocates.
#   (3) A Zone Group claim cached the group as ours, then dropped the
#       accrued delta and recounted. A writer allocating in between
#       accrued a debit after the drop for a block the recount already
#       held. Staged: zg_reconcile_stall_ms holds the recount while a
#       second writer runs out of its own space.
#
# DISCRIMINATION: (1) with a refused delta returned as an error the
# refusal repeats on every flush and syncfs fails. (2) has two
# interleavings, one per half of the fix: with the count read and
# credited after set_bg_owner() (the old order) the "held" case counts
# the second writer twice; with the count read before but credited
# after, the "flush" case's debit lands on an aggregate that does not
# hold the group yet and is dropped. (3) with the ownership cached before
# the recount, fsck reports the aggregate below its Block Groups.
# NOT COVERED: the claim mutex's other half -- a heartbeat re-attach
# caching the Zone Group mid-recount. A tick inside the stall also runs
# the surplus release, whose drain has its own suite
# (release_drain_no_enospc); the heartbeat is slowed here so neither runs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in bg_claim_stall_ms zg_reconcile_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
ZG_POKE="$(ct_helper zg_poke)"
BG_POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
ct_param_set scrub 0

# The filled Block Group's bits name no file, which fsck reports as a
# leak; only the aggregate is this suite's question.
fsck_aggregate() { # $1 dev, $2 label
    local out
    out="$(ct_fsck "$1" 2>&1 || true)"
    if grep -q "aggregate free_data_blocks" <<<"$out"; then
        fail "$2: $(grep -m1 'aggregate free_data_blocks' <<<"$out")"
    else
        pass "$2: fsck finds the aggregate equal to its Block Groups"
    fi
}
fsck_baseline() { # $1 dev
    local out
    out="$(ct_fsck "$1" 2>&1 || true)"
    ! grep -q "aggregate free_data_blocks" <<<"$out" ||
        { fail "setup: the aggregate is off before the workload: $(grep -m1 'aggregate' <<<"$out")"; ct_exit; }
}
# Two writers: the first runs out and claims, the second arrives while
# the claim holds its stall and allocates from what it is claiming. $2
# says when the second one's debit reaches the device: "held" keeps its
# file open past the stall (the close is a durability boundary), "flush"
# closes and syncs inside it.
two_writers() { # $1 mount, $2 held|flush
    local p1 p2
    R1=0 R2=0
    dd if=/dev/zero of="$1/w1" bs=64k count=128 status=none 2>/dev/null &
    p1=$!
    sleep 0.5
    if [ "$2" = held ]; then
        (
            exec 3>"$1/w2"
            dd if=/dev/zero bs=64k count=32 status=none >&3 2>/dev/null || exit 1
            sleep 5
        ) &
    else
        (dd if=/dev/zero of="$1/w2" bs=64k count=32 status=none 2>/dev/null && sync -f "$1") &
    fi
    p2=$!
    wait "$p1" || R1=$?
    wait "$p2" || R2=$?
}

# ------------------------------------------------ (1) a refused delta is dropped
IMG="$(ct_image 560 zgref)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgref)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
dd if=/dev/zero of="$MNT/a" bs=4096 count=16 conv=fsync status=none
sync -f "$MNT"
"$ZG_POKE" "$DEV" 0 free 0 >/dev/null
MARK="$(dmesg_mark)"
dd if=/dev/zero of="$MNT/b" bs=4096 count=64 status=none
sync -f "$MNT" 2>/dev/null || true # the refusal
N1="$(dmesg_since "$MARK" | grep -c "would take the aggregate below zero" || true)"
[ "$N1" -ge 1 ] || { fail "setup: the poked aggregate was never asked to go below zero"; ct_umount "$MNT"; ct_exit; }
sleep 7 # three heartbeat flushes
SYNC_OK=1
for _ in 1 2 3; do
    touch "$MNT/b"
    sync -f "$MNT" 2>/dev/null || SYNC_OK=""
done
N2="$(dmesg_since "$MARK" | grep -c "would take the aggregate below zero" || true)"
[ "$N2" = "$N1" ] && pass "a refused aggregate delta was not retried ($N1 refusal)" ||
    fail "the refused delta came back on later flushes ($N1 -> $N2 refusals)"
[ -n "$SYNC_OK" ] && pass "syncfs succeeds after the refusal" || fail "syncfs keeps failing after the refusal"
dmesg_since "$MARK" | grep -q "ZG 0: dropping the delta" && pass "the drop is logged as such" ||
    fail "the drop was not logged"
ct_umount "$MNT"

# ------------------------------------------------ (2) a Block Group claim
# Two Block Groups in one Zone Group: 0 full (bitmap and count), 1 owned
# by nobody, so the first allocation claims 1. The heartbeat is slowed
# so no tick flushes inside the stall: only the writers decide.
ct_param_set hb_interval_secs 30
for MODE in held flush; do
    IMG="$(ct_image 1200 zgbg)"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt zgbg)"
    ct_track mnt "$MNT"
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    NBG="$("$MAP" "$DEV" | grep -c '^bg ' || true)"
    [ "$NBG" = 2 ] || { fail "setup: want 2 Block Groups, got $NBG"; ct_exit; }
    "$BG_POKE" "$DEV" 1 --owner 65535 >/dev/null
    "$BG_POKE" "$DEV" 0 0 sync-zg >/dev/null # moves the aggregate with the count
    "$BG_POKE" "$DEV" 0 0 fill-bitmap >/dev/null
    fsck_baseline "$DEV"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set auto_defrag 0
    MARK="$(dmesg_mark)"
    ct_param_set bg_claim_stall_ms 3000
    two_writers "$MNT" "$MODE"
    LEFT="$(cat /sys/module/cetrafs/parameters/bg_claim_stall_ms)"
    ct_param_set bg_claim_stall_ms 0
    sync
    [ "$LEFT" = 0 ] && dmesg_since "$MARK" | grep -q "claim: allocatable, pausing" ||
        { fail "setup: no Block Group claim reached the stall"; ct_umount "$MNT"; ct_exit; }
    [ "$R1" = 0 ] && [ "$R2" = 0 ] || { fail "setup: a writer failed ($R1/$R2)"; ct_umount "$MNT"; ct_exit; }
    ct_umount "$MNT"
    fsck_aggregate "$DEV" "(2, debit $MODE) a Block Group claimed under a concurrent writer"
done

# ------------------------------------------------ (3) a Zone Group claim
# Two Zone Groups of one Block Group each; the one this node owns is
# filled, so the first allocation claims the other.
IMG="$(ct_image 1200 zgzg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgzg)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OWNED="$(grep -oP 'zg \K[0-9]+(?=: owner=[0-9]+ \(this node\))' "$(ct_procdir "$DEV")/info" || true)"
[ "$(wc -w <<<"$OWNED")" = 1 ] || { fail "setup: this node owns Zone Groups '$OWNED' after mount, want one"; ct_umount "$MNT"; ct_exit; }
ct_umount "$MNT"
for b in $(ct_bgs_of_zg "$DEV" "$OWNED"); do
    "$BG_POKE" "$DEV" "$b" 0 sync-zg >/dev/null
    "$BG_POKE" "$DEV" "$b" 0 fill-bitmap >/dev/null
done
fsck_baseline "$DEV"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
MARK="$(dmesg_mark)"
ct_param_set zg_reconcile_stall_ms 3000
two_writers "$MNT" held
LEFT="$(cat /sys/module/cetrafs/parameters/zg_reconcile_stall_ms)"
ct_param_set zg_reconcile_stall_ms 0
sync
[ "$LEFT" = 0 ] && dmesg_since "$MARK" | grep -q "reconcile: delta dropped, pausing" ||
    { fail "setup: no Zone Group claim reached the stall"; ct_umount "$MNT"; ct_exit; }
[ "$R1" = 0 ] && [ "$R2" = 0 ] && pass "(3) both writers completed across the claim (no spurious ENOSPC)" ||
    fail "(3) a writer failed while the other one claimed ($R1/$R2)"
ct_umount "$MNT"
fsck_aggregate "$DEV" "(3) a Zone Group claimed under a concurrent writer"
ct_exit
