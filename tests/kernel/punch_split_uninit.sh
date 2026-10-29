#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# punching PART of a preallocated range leaves the rest reading zeros
#
# fallocate(KEEP_SIZE) gives a file blocks it has never written. They
# read as zeros BECAUSE the extent carries CETRAFS_EXT_UNINIT -- the
# blocks still hold their previous owner's data. A punch that overlaps
# such an extent trims or splits it, and every rewrite of the length
# goes through cetrafs_extent_pack_len(len, uninit), which packs that
# flag into the length's high bit. Both cetrafs_leaf_array_punch() and
# its truncate sibling cetrafs_leaf_array_trim() passed a hardcoded 0,
# so the surviving head/tail silently became ordinary data and started
# serving whatever was in those blocks.
#
# Found by tests/kernel/churn_oracle.sh as "HOLE HOLDS DATA ... holds
# file_id=X": one file reading a deleted file's contents. Single node,
# loop device, no crash, no concurrency needed -- and the filesystem
# stayed perfectly consistent throughout (fsck clean, one owner per
# block). It was simply returning the wrong bytes, which is why no
# consistency check could ever have caught it.
#
# Discrimination: this reproduces deterministically, so the control is
# the fix itself -- revert either pack_len call and the blocks below
# come back reading "DONOR-block-N".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PROBE="$(ct_helper punch_split_probe)"
DEV="$(ct_dev 600 punchsplit)"
MNT="$(ct_mnt punchsplit)"

ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "write and delete a donor, preallocate over its blocks, punch part of that"
OUT="$("$PROBE" "$MNT")" && rc=0 || rc=$?
echo "$OUT" | sed 's/^/    /'

if [ "$rc" = 0 ]; then
    pass "the surviving part of the preallocated range still reads zeros"
else
    fail "a preallocated range that was partly punched serves another file's data: $(grep -m1 'block' <<<"$OUT")"
fi

# Cold, off the device -- the extent flag is on disk, not a page-cache
# property, so this must hold after the cache is gone.
echo 3 >/proc/sys/vm/drop_caches
OUT2="$("$PROBE" "$MNT")" && rc2=0 || rc2=$?
[ "$rc2" = 0 ] && pass "and still zeros on a fresh volume read" ||
    fail "the preallocated range serves stale data cold: $(grep -m1 'block' <<<"$OUT2")"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean (the damage was never a consistency fault)" ||
    fail "fsck reports a problem: $(ct_fsck "$DEV" 2>&1 | grep -m1 -iE 'ERR|overlap|leaked')"

ct_exit
