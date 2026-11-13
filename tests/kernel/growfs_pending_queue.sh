#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow leaves a Zone Group's pending-free queue where it is, and the next mount drains it
#
# The pending-free queue is indexed by Zone Group, and a grow never
# changes the Zone Group count, so the queue must come through a grow
# byte-identical at its own address. A grow that relocated or zeroed it
# would drop frees a peer had already queued: their blocks stay
# allocated for good, and nothing reclaims them but a scrub.
#
# Staged on one node. A 4-block file is given an empty extent list
# (inode_block_poke ehset entries 0) while its bitmap bits stay set: the
# blocks belong to nobody, which is the state a peer's unlink leaves
# before the owner drains. Two queue entries name them. Then the volume
# is grown and mounted. Two things must hold:
#   - the queue reads back identically after the grow;
#   - the mount drains both entries, so the volume ends 4 blocks freer
#     than an identical control volume that never queued them.
# The control is a second run with the same leak and no entries, so the
# free count is a differential rather than a guessed number.
#
# DISCRIMINATION: CETRAFS_GROWFS_TEST_CLOBBER_PENDING zeroes Zone Group
# 0's queue during the grow. The control round must see that loss; if
# the queue-survives assertion still passed, this suite proves nothing.
#
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PFPOKE="$(ct_helper pending_poke)"
IBPOKE="$(ct_helper inode_block_poke)"
DEV="$(ct_big_dev 1200 gpq)"
MNT="$(ct_mnt gpq)"
ct_track mnt "$MNT"
ct_param_set scrub 0 # a background scrub would reclaim the leaked blocks itself
ct_param_set auto_defrag 0

# round <tag> <with_entries 0|1> [VAR=value ...]
# Sets R_SURVIVED (queue identical after the grow), R_FREE (free blocks
# after the mount), R_PRE and R_QUEUE (queue before the grow and after
# the mount). Returns 1 if the setup did not arrange the situation.
round() {
    local tag="$1" entries="$2" ino lba len
    shift 2
    ct_mkfs "$DEV" -s 600M -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/leak" bs=4096 count=4 conv=fsync status=none
    ino="$(stat -c %i "$MNT/leak")"
    ct_umount "$MNT"
    read -r lba len <<<"$("$PFPOKE" "$DEV" extent "$ino" 2>/dev/null || true)"
    if [ -z "$lba" ] || [ "${len:-0}" -lt 4 ]; then
        fail "$tag: setup: no 4-block extent for the leaked file (lba='$lba' len='$len')"
        return 1
    fi
    # The blocks the file no longer names, with their bitmap bits still set.
    "$IBPOKE" "$DEV" ehset "$ino" entries 0 >/dev/null
    if [ "$entries" = 1 ]; then
        "$PFPOKE" "$DEV" add 0 "$lba" 2 >/dev/null
        "$PFPOKE" "$DEV" add 0 $((lba + 2)) 2 >/dev/null
    fi
    R_PRE="$("$PFPOKE" "$DEV" dump 0)"
    if [ "$entries" = 1 ] && [ -z "$R_PRE" ]; then
        fail "$tag: setup: the queue is empty before the grow -- nothing to carry over"
        return 1
    fi
    if ! env "$@" "$ROOT/userspace/growfs.cetra" "$DEV" -s 1200M >/dev/null 2>&1; then
        fail "$tag: the grow failed"
        return 1
    fi
    R_SURVIVED=0
    [ "$R_PRE" = "$("$PFPOKE" "$DEV" dump 0)" ] && R_SURVIVED=1
    mount -t cetrafs "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    R_FREE="$(stat -f -c '%f' "$MNT")"
    umount "$MNT"
    R_QUEUE="$("$PFPOKE" "$DEV" dump 0)"
    return 0
}

# ---- the queued case: the grow keeps the queue, the mount drains it
round queued 1 || ct_exit
if [ "$R_SURVIVED" = 1 ]; then
    pass "queued: the Zone Group's queue reads back identically after the grow"
else
    fail "queued: the queue changed across the grow (before: '$R_PRE')"
fi
[ -z "$R_QUEUE" ] && pass "queued: the mount consumed both entries" ||
    fail "queued: entries survived the mount: $R_QUEUE"
FREE_Q="$R_FREE"

# ---- the control: the same leak, nothing queued
round unqueued 0 || ct_exit
FREE_U="$R_FREE"
if [ "$((FREE_Q - FREE_U))" = 4 ]; then
    pass "queued: the mount freed exactly the 4 leaked blocks (control $FREE_U free, queued $FREE_Q free)"
else
    fail "queued: the mount freed $((FREE_Q - FREE_U)) blocks, expected 4 (control $FREE_U, queued $FREE_Q)"
fi

# ---- the negative control: a grow that loses the queue must be seen
round clobbered 1 CETRAFS_GROWFS_TEST_CLOBBER_PENDING=1 || ct_exit
if [ "$R_SURVIVED" = 0 ]; then
    pass "control: a grow that zeroes the queue is caught (the survival check fails)"
else
    fail "control: a grow that zeroed the queue passed the survival check -- the check does not discriminate"
fi

ct_exit
