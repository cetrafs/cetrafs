#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag step moves at most the step cap under the locks, whatever the extent sizes
#
# Each defrag step holds inode_lock and invalidate_lock while it copies,
# so a guest write, a direct I/O or a page fault on the file waits for the
# step. The step was "up to 128 blocks, rounded UP to the next whole
# extent" -- so a file whose first extent is 64 MiB moved all of it in
# one step, and everything waited for the whole copy (audit 2026-11-06
# M9). An extent past the cap is now split there.
#
# Staged: a 64 MiB file written in one go (one large extent), then a
# block appended after another file took the space behind it (a second
# extent, so there is something to defragment). The pass must report no
# step above 128 blocks (procfs info, defrag_max_step_blocks), and the
# file must read back unchanged with fsck clean -- the split commit
# publishes half an extent and must get both halves right.
#
# DISCRIMINATION: with whole-extent steps, the largest step is the large
# extent's length.
# NOT COVERED: the stop checks added inside a step (drain, fence,
# SIGKILL) -- a step is now short enough that nothing here can hold one
# open long enough to aim at it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }

DEV="$(ct_dev 560 defragstep)"
MNT="$(ct_mnt defragstep)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
maxstep() { sed -n 's/^defrag_max_step_blocks: //p' "$INFO"; }

dd if=/dev/urandom of="$MNT/big" bs=1M count=64 conv=fsync status=none
dd if=/dev/zero of="$MNT/other" bs=1M count=1 conv=fsync status=none
dd if=/dev/urandom of="$MNT/big" bs=4096 count=1 seek=16384 conv=notrunc,fsync status=none
LENS="$(filefrag -v -b4096 "$MNT/big" | awk -F: '$1 ~ /^ *[0-9]+$/ { split($2, a, "[.]+"); print a[2] - a[1] + 1 }')"
NEXT="$(grep -c . <<<"$LENS")"
BIGGEST="$(sort -n <<<"$LENS" | tail -1)"
[ "$NEXT" -ge 2 ] && [ "$BIGGEST" -gt 1024 ] ||
    { fail "setup: want >= 2 extents with one past 1024 blocks, got $NEXT extents, largest $BIGGEST"; ct_umount "$MNT"; ct_exit; }
BEFORE="$(md5sum <"$MNT/big")"
M0="$(maxstep)"
[ -n "$M0" ] || { fail "setup: procfs info has no defrag_max_step_blocks"; ct_umount "$MNT"; ct_exit; }

"$ROOT/userspace/defrag.cetra" "$MNT/big" >/dev/null 2>&1 || true
M1="$(maxstep)"
AFTER_EXT="$(filefrag "$MNT/big" | sed -n 's/.*: \([0-9]*\) extents\{0,1\} found.*/\1/p')"
[ "$M1" -gt 0 ] && [ "${AFTER_EXT:-$NEXT}" -lt "$NEXT" ] ||
    { fail "setup: the defrag did not run (largest step $M1, extents $NEXT -> $AFTER_EXT)"; ct_umount "$MNT"; ct_exit; }
[ "$M1" -le 128 ] && pass "no defrag step moved more than 128 blocks (largest $M1, extent of $BIGGEST)" ||
    fail "a defrag step moved $M1 blocks under the locks (the cap is 128; the largest extent was $BIGGEST)"
echo 3 >/proc/sys/vm/drop_caches
[ "$(md5sum <"$MNT/big")" = "$BEFORE" ] && pass "the file reads back unchanged across the split steps" ||
    fail "the file changed across the defrag"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean after the split steps" ||
    fail "fsck: $(grep -i err <<<"$OUT" | head -2)"
ct_exit
