#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a store through a mapping that waits behind a punch can still be killed
#
# page_mkwrite takes mapping->invalidate_lock exclusively before it
# allocates (CLAUDE.md rule 18). Its holder may be a punch or truncate
# doing device I/O for seconds, and the wait was uninterruptible: a
# process storing into the mapping sat in D state, SIGKILL included,
# until the holder finished (audit L21). The wait is now killable; the
# O_DIRECT allocating get_block takes the same killable wait.
#
# Staged: a mapped page, read in clean (so the first store faults to
# page_mkwrite), and a punch elsewhere in the file held inside
# invalidate_lock by punch_pagecache_delay_ms. The store blocks; it is
# killed; it must be gone long before the punch lets go.
#
# DISCRIMINATION: the setup check requires the store to be blocked (D)
# behind the held lock before the kill. The reverted-fix control
# (filemap_invalidate_lock() restored in page_mkwrite) has not been run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 mkk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mkk)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
dd if=/dev/urandom of="$MNT/f" bs=1M count=4 conv=fsync status=none
GO="$(ct_tmp mkk-go)"
rm -f "$GO"

python3 - "$MNT/f" "$GO" <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
m = mmap.mmap(fd, 4 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
_ = m[2 << 20]            # read fault: the page is mapped clean
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
m[2 << 20] = 0x78         # write fault -> page_mkwrite
time.sleep(60)
PY
PID=$!
sleep 1
ct_param_set punch_pagecache_delay_ms 8000
fallocate -p -o 0 -l 4096 "$MNT/f" &
PUNCH=$!
sleep 1
touch "$GO"
sleep 1.5
ST="$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null || echo gone)"
log "the storing process is in state $ST"
[ "$ST" = D ] || { fail "setup: the store is not waiting (state $ST) -- the punch did not hold invalidate_lock over it"; kill -9 "$PID" 2>/dev/null; wait "$PUNCH" || true; ct_param_set punch_pagecache_delay_ms 0; ct_exit; }
T0="$(date +%s.%N)"
kill -9 "$PID"
wait "$PID" 2>/dev/null || true
T1="$(date +%s.%N)"
PUNCH_ALIVE=0
kill -0 "$PUNCH" 2>/dev/null && PUNCH_ALIVE=1
wait "$PUNCH" || true
ct_param_set punch_pagecache_delay_ms 0
EL="$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%.2f", b - a }')"
log "killed after ${EL}s; the punch was still holding the lock: $PUNCH_ALIVE"
[ "$PUNCH_ALIVE" = 1 ] && pass "SIGKILL ended the waiting store (${EL}s) while the punch still held the lock" ||
    fail "the store outlived its SIGKILL until the punch let go (${EL}s)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
