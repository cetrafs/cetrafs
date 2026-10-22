#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# cetrafs_get_block() must report contiguous runs, not one block at a time
#
# map_bh() hard-sets b_size to a single block, so a get_block() that ends
# there forces every caller back once per 4 KiB no matter how contiguous
# the file is. The buffered paths don't care -- they map one buffer at a
# time anyway -- but blockdev_direct_IO() and mpage_writepages() hand in a
# b_size covering the WHOLE remaining request and use what we return to
# learn how much got mapped. O_DIRECT has no page cache to amortise the
# callback, and qemu cache=none (Proxmox's default for shared storage) is
# exactly O_DIRECT, so this is the path a running VM lives on.
#
# Reported runs are clamped to what the caller asked for, which is also
# required for correctness: __block_write_begin/block_read_full_folio pass
# a REAL buffer_head off a folio, sized to one block, and widening that
# would corrupt it. So buffered stays 1:1 and only the multi-block callers
# see more -- both directions are asserted below.
#
# Discrimination: drop the b_size widening in cetrafs_get_block() and
# map_blocks tracks map_calls exactly, so the first assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 gbrun)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt gbrun)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
calls()  { sed -n 's/^map_calls: //p' "$PROC"; }
blocks() { sed -n 's/^map_blocks: //p' "$PROC"; }

[ -n "$(calls)" ] || fail "procfs has no map_calls counter"

# An 8 MiB file written in one go: contiguous, so one extent.
dd if=/dev/zero of="$MNT/f" bs=1M count=8 conv=fsync status=none
sync
echo 3 > /proc/sys/vm/drop_caches

# ---- O_DIRECT read: the path that asks for a big mapping ----
C0="$(calls)"; B0="$(blocks)"
python3 - "$MNT/f" <<'PY'
import os, sys, mmap, ctypes
n = 8 << 20
buf = mmap.mmap(-1, n + 4096)
off = (-ctypes.addressof(ctypes.c_char.from_buffer(buf))) % 4096
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
got = os.preadv(fd, [memoryview(buf)[off:off+n]], 0)
os.close(fd)
assert got == n, got
PY
C1="$(calls)"; B1="$(blocks)"

DC=$((C1 - C0)); DB=$((B1 - B0))
log "O_DIRECT read of 2048 blocks: $DC get_block calls covering $DB blocks"

[ "$DC" -gt 0 ] || fail "no mappings were recorded -- the test observed nothing"

# THE assertion: more blocks mapped than calls made.
[ "$DB" -gt "$DC" ] ||
    fail "get_block mapped $DB blocks in $DC calls -- one block per call, runs are not reported"

# Measured: ONE call maps all 2048 blocks. 1024 permitted a call every
# two blocks -- it would have passed against code that had barely
# improved, while the unfixed version produces exactly 2048.
[ "$DC" -lt 64 ] ||
    fail "$DC get_block calls for 2048 contiguous blocks -- barely better than one per block"

# ---- buffered read: must stay exactly 1 block per call ----
echo 3 > /proc/sys/vm/drop_caches
C2="$(calls)"; B2="$(blocks)"
dd if="$MNT/f" of=/dev/null bs=1M count=8 status=none
C3="$(calls)"; B3="$(blocks)"
BC=$((C3 - C2)); BB=$((B3 - B2))
log "buffered read: $BC calls covering $BB blocks"
[ "$BC" -gt 0 ] && [ "$BB" -eq "$BC" ] ||
    fail "buffered read got $BB blocks in $BC calls -- it must stay 1:1 (a widened folio bh is corruption)"

# ---- the data must still be right ----
cmp -s <(dd if=/dev/zero bs=1M count=8 status=none) "$MNT/f" ||
    fail "file contents differ after run-mapped reads"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"

pass "get_block reports contiguous runs to O_DIRECT and stays 1:1 for buffered callers"

ct_exit
