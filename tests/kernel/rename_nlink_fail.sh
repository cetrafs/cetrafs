#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rename's link-count swap that fails is retried, and said, not swallowed
#
# Renaming over a file drops the replaced file's link count by a swap
# made after its name is already gone. A failed swap was dropped without
# a word -- its error lost in a 'ret' the next step overwrote -- leaving
# the replaced file (a VM image a restore renamed over) unreachable with
# nlink 1: evict frees nothing, the scrub reclaims only nlink 0, and its
# whole extent set leaked until fsck. The moved file's own final -1 had
# the same shape.
#
# A: one failed swap -- the retry lands it; the replaced file is freed
#    and fsck is clean.
# B: every attempt fails -- the leak must be reported by name.
#
# DISCRIMINATION: without the retry A leaves fsck reporting the replaced
# inode's link count; without the report B logs nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/rename_nlink_fail ] || { skip "rename_nlink_fail is missing"; ct_exit; }

IMG="$(ct_image 560 rnnlink)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rnnlink)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# --- A
dd if=/dev/urandom of="$MNT/old.img" bs=4096 count=32 status=none
echo new >"$MNT/new.img"
sync
OLD="$(stat -c %i "$MNT/old.img")"
MARK="$(dmesg_mark)"
ct_param_set rename_nlink_fail 1
mv "$MNT/new.img" "$MNT/old.img"
[ "$(cat /sys/module/cetrafs/parameters/rename_nlink_fail)" = 0 ] ||
    { fail "A: setup: the injected failure did not fire"; ct_exit; }
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE "^(ERR|WARN).*inode $OLD\b" <<<"$OUT" &&
    fail "A: one refused swap left the replaced inode $OLD wrong: $(grep -E "inode $OLD\b" <<<"$OUT" | head -2)" ||
    pass "A: the retry landed the replaced file's -1 (fsck has nothing on inode $OLD)"
grep -qE '^ERR' <<<"$OUT" && fail "A: fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "A: fsck clean"

# --- B
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/b.img" bs=4096 count=8 status=none
echo n >"$MNT/b.new"
sync
BI="$(stat -c %i "$MNT/b.img")"
MARK="$(dmesg_mark)"
ct_param_set rename_nlink_fail 3
mv "$MNT/b.new" "$MNT/b.img"
ct_param_set rename_nlink_fail 0
dmesg_since "$MARK" | grep -q "rename: replaced file ino=$BI kept a link count one too high" &&
    pass "B: the leak is reported, naming inode $BI" ||
    fail "B: a rename that could not drop inode $BI's link count said nothing"
ct_umount "$MNT"
ct_exit
