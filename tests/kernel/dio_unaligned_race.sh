#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two sub-block O_DIRECT writes in flight against one fresh block
#
# An O_DIRECT write into a preallocated block or a hole stays direct,
# and the block reads as zeros until the write's completion converts it.
# Until then the DIO code treats it as new and zeroes whatever part of
# it the write does not cover. A second sub-block write to the same
# block, submitted while the first is still in flight, therefore maps it
# as new too, and each one's zeros land on the other's data. inode_lock
# serialises submission only; an async writer (Linux AIO, io_uring --
# qemu's aio=native) drops it with the bio in flight.
#
# An unaligned direct write now drains direct I/O before it starts and
# completes before it returns (cetrafs_dio_unaligned()), as ext4 does.
#
# The writes go through tests/helpers/dio_aio: two halves of each block
# in ONE io_submit, on a delay device so the first is certainly still in
# flight when the second maps the block.
#
# DISCRIMINATION: with the two inode_dio_wait() calls in
# cetrafs_file_write_iter() removed, nearly every block loses its first
# half to the second write's zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dio_fill_holes ] || { skip "dio_fill_holes is missing"; ct_exit; }

AIO="$(ct_helper dio_aio)"
DEV="$(ct_delay_dev 560 2 diounal)"
[ -n "$DEV" ] || { skip "dm-delay is not available"; ct_exit; }
MNT="$(ct_mnt diounal)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }
ct_param_set auto_defrag 0
ct_param_set dio_fill_holes 1

N=512
for mode in falloc hole; do
    for half in 2048 512; do
        F="$MNT/$mode.$half"
        python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
if sys.argv[2] == "falloc": os.posix_fallocate(fd, 0, int(sys.argv[3]) * 4096)
else: os.ftruncate(fd, int(sys.argv[3]) * 4096)
os.close(fd)' "$F" "$mode" "$N"
        log "$mode: two $half-byte halves of each of $N fresh blocks, in flight together"
        C0="$(ctr dio_converts)"
        F0="$(ctr dio_fallbacks)"
        OUT="$("$AIO" pair "$F" "$N" "$half")" || fail "$mode/$half: a write failed: $OUT"
        C1="$(ctr dio_converts)"
        F1="$(ctr dio_fallbacks)"
        # Setup: the writes took the direct path into new blocks. Without
        # that this would pass against the race it exists to catch.
        [ "$F1" = "$F0" ] && [ "$((C1 - C0))" -ge "$N" ] ||
            fail "$mode/$half: setup: $((C1 - C0)) conversions and $((F1 - F0)) fallbacks -- the writes did not go direct into new blocks"
        grep -q " lost=0 " <<<"$OUT" &&
            pass "$mode/$half: both halves of every block survive ($OUT)" ||
            fail "$mode/$half: one write's zeros landed on the other's data: $OUT"
    done
done

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
