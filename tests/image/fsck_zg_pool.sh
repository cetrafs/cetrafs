#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck cross-checks the unowned-BG pool shard against the real unowned set.
#
# pool_free_blocks (cetrafs_zone_group_t, hot sector) counts the capacity
# of unowned Block Groups sharded to each ZG record, so statfs keeps
# counting space a node handed back -- without it, df shrank by a group's
# whole capacity (~512 MiB) at every surplus release (three-node xattrs
# scenario, 2026-10-28). A wrong shard misstates df cluster-wide; fsck
# must say so, and -r must restore the truth.
#
# The injected fault IS the negative control: a fresh mkfs owns every
# Block Group, so every shard must read zero -- poking one nonzero is
# unambiguously corrupt, and a checker that misses it calls every broken
# volume clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
suite "fsck: unowned-BG pool shard cross-check"

POKE="$(ct_helper bg_poke)"
IMG="$(ct_image 560 zgpool)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null

ct_fsck "$DEV" >/dev/null 2>&1 && pass "fresh image is clean" || fail "fresh image not clean"

# Stamp a bogus pool count into ZG0 with the checksum restamped the way
# the kernel would, so ONLY the cross-check can catch it -- a checksum
# error here would prove nothing about the check under test.
"$POKE" "$DEV" zg-pool 0 123456
blockdev --flushbufs "$DEV"

OUT="$(ct_fsck "$DEV" 2>&1)" && RC=0 || RC=$?
if grep -q "pool_free_blocks" <<<"$OUT" && [ "$RC" != 0 ]; then
    pass "fsck reports the corrupt pool shard and exits nonzero"
else
    fail "fsck MISSED a corrupt pool shard (rc=$RC): $(head -2 <<<"$OUT" | tr '\n' ' ')"
fi

"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true
ct_fsck "$DEV" >/dev/null 2>&1 && pass "-r restores the shard and the image is clean again" ||
    fail "repair did not restore the pool shard: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"

ct_exit
