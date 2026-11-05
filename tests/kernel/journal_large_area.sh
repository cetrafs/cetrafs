#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a large per-node journal mounts and replays; one past the format's bound is refused
#
# The journal sizes per-slot arrays from the superblock: a busy bitmap and
# a held-slot array at every mount, and 48 bytes per slot at every replay.
# They were kmalloc'd with no bound on the slot count, so a large -J (or a
# hostile image) asked kmalloc for more than it can ever give -- a
# WARNING and a failed mount -- and nothing capped the field at all
# (audit 2026-11-05, class 13/12).
#
# A 1 GiB journal (131071 slots) puts replay's array at 6.3 MB, past
# kmalloc's limit: with a live entry left by a failed target write, the
# remount's own replay must go through. And mkfs, the mount and fsck
# refuse a per-node journal past CETRAFS_JOURNAL_MAX_BLOCKS (16 GiB).
#
# DISCRIMINATION: proven 2026-11-05 against kmalloc_array (and the old
# mkfs): the remount fails with a page-allocator WARNING, and mkfs
# accepts -J 16385.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 1700 jlarge)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jlarge)"
ct_track mnt "$MNT"

# By the bound's own message: this image is too small for 16 GiB anyway,
# and a refusal for THAT would prove nothing about the bound.
MO="$(ct_mkfs "$DEV" -z 1 -b 512 -J 16385 -M 1 -N 1024 -f 2>&1 || true)"
grep -q -- "-J too large (max 16384 MiB per node)" <<<"$MO" &&
    pass "mkfs refuses a per-node journal past 16384 MiB, by the format's bound" ||
    fail "mkfs did not refuse -J 16385 for the format's bound: $(tail -1 <<<"$MO")"

ct_mkfs "$DEV" -z 1 -b 512 -J 1024 -M 1 -N 1024 -f >/dev/null || { fail "setup: mkfs -J 1024 failed"; ct_exit; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
pass "a volume with a 1 GiB per-node journal mounts"
PROC="$(ct_procdir "$DEV")/info"
c() { sed -n "s/^$1: //p" "$PROC"; }
mkdir "$MNT/d"
: >"$MNT/d/warm"
sync
ct_param_set journal_fail_target_write 1
: >"$MNT/d/live" 2>/dev/null || true
ct_param_set journal_fail_target_write 0
ct_umount "$MNT"
MARK="$(dmesg_mark)"
if ct_mount "$DEV" "$MNT" 2>/dev/null; then
    pass "the remount over a dirty 1 GiB journal went through"
    dmesg_since "$MARK" | grep -q "journal replay: node 0 replayed" &&
        pass "and replayed this node's area" || fail "the remount did not replay the area: $(dmesg_since "$MARK" | grep -i journal | tail -2)"
    ct_umount "$MNT"
else
    fail "the remount over a dirty 1 GiB journal failed: $(dmesg_since "$MARK" | grep -iE 'journal|warn|alloc' | tail -3)"
fi

# The mount and fsck refuse the field past the bound.
SBP="$(ct_helper sb_poke)"
"$SBP" "$IMG" node_journal_blocks 4194305 >/dev/null
blockdev --flushbufs "$DEV"
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    fail "the mount accepted a per-node journal past the format's bound"
    umount "$MNT"
else
    dmesg_since "$MARK" | grep -q "per-node journal of 4194305 blocks exceeds" &&
        pass "the mount refuses a per-node journal past the bound, and says why" ||
        fail "the mount refused, but not for the journal's size: $(dmesg_since "$MARK" | grep superblock | tail -2)"
fi
fo="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "per-node journal of 4194305 blocks exceeds" <<<"$fo" && pass "and so does fsck" ||
    fail "fsck did not refuse the oversized journal: $(grep ERR <<<"$fo" | head -2)"
ct_exit
