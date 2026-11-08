#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free queued twice is applied once: the second copy cannot free a block reallocated in between
#
# The pending-free drain consumes a batch of queue entries and then
# applies each under its own alloc_mutex hold. A free queued twice (a
# tolerated double free leaves exactly that) was applied twice, and an
# allocation landing between the two applies got its block freed by the
# second: a live file's block reading FREE, handed to the next writer
# (audit 2026-11-06 L19).
#
# Staged on a live mount: a one-block file is written and removed, so
# its block L is free and is the next one the allocator hands out. Two
# entries for L are planted in ZG 0's queue. A writer then triggers an
# on-demand drain, which pf_apply_stall_ms holds between its applies;
# a second writer allocates in that window and gets L. When the drain
# resumes, L must stay that writer's, and the first writer must get a
# different block.
#
# Twice: both copies in one CAS region of the queue, and in two (the
# drain consumes and applies region by region, so a check scoped to one
# region sees only the first case).
#
# And a third time with a SECOND drain in the window: a third writer,
# allowed to drain, runs while the first drain is held and the second
# writer already owns L. Its drain would consume the region with the
# copy and apply it without seeing what the first applied; one drain at
# a time (pf_drain_mutex) leaves the region to the first, which drops
# the copy.
#
# DISCRIMINATION: applying every consumed entry, the second copy frees
# L under the second writer and the first writer is handed L as well --
# two files share one block. Deduplicating per region fails the
# cross-region case alone. Letting drains run concurrently fails the
# third case alone: the third writer is handed L.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pf_apply_stall_ms ] || { skip "pf_apply_stall_ms is missing"; ct_exit; }
PP="$(ct_helper pending_poke)"

IMG="$(ct_image 560 pfdup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfdup)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }

# race <tag> <fillers>: free one block L, queue it, <fillers> already-free
# blocks after it, and L again -- with 31 fillers the second copy is slot
# 32, the first slot of the queue's second CAS region. Then the writers.
race() {
    local tag="$1" nfill="$2" L F2 G i
    dd if=/dev/urandom of="$MNT/f1$tag" bs=4096 count=1 conv=fsync status=none
    sync
    L="$(ext "$MNT/f1$tag")"
    [ -n "$L" ] || { fail "$tag setup: no extent for f1"; return; }
    rm -f "$MNT/f1$tag"
    sync
    "$PP" "$IMG" add 0 "$L" 1 >/dev/null
    for i in $(seq 1 "$nfill"); do "$PP" "$IMG" add 0 $((L + 4000 + i)) 1 >/dev/null; done
    "$PP" "$IMG" add 0 "$L" 1 >/dev/null
    [ "$("$PP" "$IMG" dump 0 | sed -n "$((nfill + 2))p")" = "$L 1" ] ||
        { fail "$tag setup: the second copy is not at slot $((nfill + 1))"; return; }
    log "$tag: block $L freed and queued at slots 0 and $((nfill + 1))"

    MARK="$(dmesg_mark)"
    ct_param_set pf_drain_min_ms 0
    ct_param_set pf_apply_stall_ms 4000 # one-shot: after the first apply
    dd if=/dev/urandom of="$MNT/g$tag" bs=4096 count=1 conv=fsync status=none &
    GPID=$!
    sleep 1
    ct_param_set pf_drain_min_ms 600000 # the second writer must not drain itself
    dd if=/dev/urandom of="$MNT/f2$tag" bs=4096 count=1 conv=fsync status=none
    wait "$GPID"
    ct_param_set pf_apply_stall_ms 0
    sync
    F2="$(ext "$MNT/f2$tag")"
    G="$(ext "$MNT/g$tag")"
    log "$tag: f2 at $F2, g at $G"
    [ "$F2" = "$L" ] || { fail "$tag setup: the second writer got block $F2, not the freed block $L"; return; }
    pass "$tag setup: the second writer allocated the queued block $L inside the drain"
    [ "$G" != "$L" ] && pass "$tag: the first writer got another block ($G): the copy did not free $L again" ||
        fail "$tag: the first writer was handed $L too -- the second copy freed the second writer's block"
    dmesg_since "$MARK" | grep -q "lba=$L count=1 overlaps a free this drain already applied" &&
        pass "$tag: and the copy was reported" || fail "$tag: the second copy was not reported"
    [ -z "$("$PP" "$IMG" dump 0)" ] && pass "$tag: every entry was consumed" ||
        fail "$tag: entries left: $("$PP" "$IMG" dump 0 | head -3)"
}

race same-region 0
race cross-region 31

# concurrent: as cross-region, then a third writer drains inside the hold
race_concurrent() {
    local tag=concurrent nfill=31 L F2 G H i
    dd if=/dev/urandom of="$MNT/f1$tag" bs=4096 count=1 conv=fsync status=none
    sync
    L="$(ext "$MNT/f1$tag")"
    [ -n "$L" ] || { fail "$tag setup: no extent for f1"; return; }
    rm -f "$MNT/f1$tag"
    sync
    "$PP" "$IMG" add 0 "$L" 1 >/dev/null
    for i in $(seq 1 "$nfill"); do "$PP" "$IMG" add 0 $((L + 5000 + i)) 1 >/dev/null; done
    "$PP" "$IMG" add 0 "$L" 1 >/dev/null
    [ "$("$PP" "$IMG" dump 0 | sed -n "$((nfill + 2))p")" = "$L 1" ] ||
        { fail "$tag setup: the second copy is not at slot $((nfill + 1))"; return; }

    MARK="$(dmesg_mark)"
    ct_param_set pf_drain_min_ms 0
    ct_param_set pf_apply_stall_ms 6000 # one-shot: after the first apply
    dd if=/dev/urandom of="$MNT/g$tag" bs=4096 count=1 conv=fsync status=none &
    GPID=$!
    sleep 1
    ct_param_set pf_drain_min_ms 600000 # the second writer must not drain
    dd if=/dev/urandom of="$MNT/f2$tag" bs=4096 count=1 conv=fsync status=none
    ct_param_set pf_drain_min_ms 0      # the third one must
    dd if=/dev/urandom of="$MNT/h$tag" bs=4096 count=1 conv=fsync status=none
    ct_param_set pf_drain_min_ms 600000
    kill -0 "$GPID" 2>/dev/null && pass "$tag setup: the third writer finished while the first drain was held" ||
        fail "$tag setup: the first drain was no longer held when the third writer ran"
    wait "$GPID"
    ct_param_set pf_apply_stall_ms 0
    sync
    F2="$(ext "$MNT/f2$tag")"
    G="$(ext "$MNT/g$tag")"
    H="$(ext "$MNT/h$tag")"
    log "$tag: f2 at $F2, g at $G, h at $H"
    [ "$F2" = "$L" ] || { fail "$tag setup: the second writer got block $F2, not the freed block $L"; return; }
    [ "$H" != "$L" ] && [ "$G" != "$L" ] &&
        pass "$tag: no other writer was handed $L: a second drain did not apply the copy" ||
        fail "$tag: $L was handed out again (g $G, h $H) -- a concurrent drain freed the second writer's block"
    dmesg_since "$MARK" | grep -q "lba=$L count=1 overlaps a free this drain already applied" &&
        pass "$tag: the first drain reported the copy" || fail "$tag: the copy was not reported by the first drain"
    [ -z "$("$PP" "$IMG" dump 0)" ] && pass "$tag: every entry was consumed" ||
        fail "$tag: entries left: $("$PP" "$IMG" dump 0 | head -3)"
}
race_concurrent

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
