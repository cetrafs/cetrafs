#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every fsck --live walk reads the device, never a page this host's cache kept
#
# --live counts a problem only if every walk repeats it, which filters a
# transient only if each walk reads the device. Each walk dropped this
# host's cache with POSIX_FADV_DONTNEED alone, and a live walk skips the
# peer probe, whose BLKFLSBUF was the other drop (audit 2026-11-15
# F-54). Neither drops a page that is mapped, locked or being read at
# that instant, so a block read damaged once could be read the same by
# all three walks: "take the volume offline", for nothing. A live walk
# now reads O_DIRECT.
#
# Staged on a loop device: the root's record is damaged on the backing
# file, a process maps that block of the device (which pulls the damaged
# copy into the cache and keeps it there, mapped), and the record is put
# back on the backing file only. fsck --live must find the volume clean.
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_LIVE_BUFFERED=1, the buffered reads
# as before: the mapped stale record repeats in every walk -- 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper csum_poke)"
SBPOKE="$(ct_helper sb_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 560 livedev)"
DEV="$(ct_loop "$IMG")"
GOOD="$(ct_tmp)"
STOP="$(ct_tmp)"

# <buffered 0|1> -> RES "stale=<y|n> rc=<n>"
round() {
    local its pid
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    blockdev --flushbufs "$DEV"
    its="$("$SBPOKE" "$IMG" | sed -n 's/^inode_table_start=//p')"
    dd if="$IMG" of="$GOOD" bs=4096 skip="$its" count=1 status=none
    "$POKE" "$IMG" inode 1 >/dev/null
    rm -f "$STOP"
    python3 -I - "$DEV" "$its" "$STOP" <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=int(sys.argv[2]) * 4096)
_ = m[0:4096]  # fault it in: the damaged copy, now mapped
while not os.path.exists(sys.argv[3]):
    time.sleep(0.1)
PY
    pid=$!
    sleep 1
    dd if="$GOOD" of="$IMG" bs=4096 seek="$its" count=1 conv=notrunc,fsync status=none
    blockdev --flushbufs "$DEV" 2>/dev/null || true
    dd if="$DEV" bs=4096 skip="$its" count=1 status=none | cmp -s - "$GOOD" && RES="stale=n" || RES="stale=y"
    RC=0
    if [ "$1" = 1 ]; then
        CETRAFS_TEST_FSCK_LIVE_BUFFERED=1 "$FSCK" --live "$DEV" >/dev/null 2>&1 || RC=$?
    else
        "$FSCK" --live "$DEV" >/dev/null 2>&1 || RC=$?
    fi
    RES="$RES rc=$RC"
    touch "$STOP"
    wait "$pid" || true
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

round 0
F="$RES"
round 1
C="$RES"
log "fixed: $F; control: $C"
[ "$(field stale "$F")" = y ] || { fail "setup: the cache did not keep the damaged record ($F)"; ct_exit; }
[ "$(field rc "$F")" = 0 ] && pass "every walk read the device: the volume is clean" ||
    fail "--live reported a record only this host's cache held: $F"
[ "$(field rc "$C")" = 1 ] && pass "control: read through the cache, the stale record repeated in every walk (1)" ||
    fail "control: the stale page did not reach the buffered walks -- the suite cannot see F-54: $C"
ct_exit
