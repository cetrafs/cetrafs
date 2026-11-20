#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# block-layer writeback never puts a fenced node's allocation bitmap on the device
#
# Allocation bitmaps were left dirty in the block device's cache, and the
# self-fence dropped them with a sweep queued AFTER the fence. Between the
# two -- and before the fence at all, on a node frozen past its lease --
# the block layer's own writeback (the flusher, an fsync of the device)
# was free to write them: a stale bitmap over the one a peer now
# allocates in, every block it handed out reading FREE again (audit
# 2026-11-14 A-15). Bitmap buffers are now HELD -- this module's own list,
# not dirty -- and only cetrafs writes them, at its durability boundaries,
# none of which runs once the mount is fenced.
#
# The peer is played on the device, as in fence_drops_dirty_metadata.sh;
# TEST ONLY stop_sweep_delay_ms holds the sweep back, and inside that
# window an fsync of the block device asks the block layer to write
# whatever it holds dirty.
#   setup: this node's new bits are only in its memory; the node fenced;
#          the sweep had not run when the device was fsynced;
#   1. the peer's bits survive.
#
# B. A held block the list could not take (xa_store failing) was dirtied
# instead -- writeback's again, and a free decided before a freeze could
# reach the device after the lease (audit 2026-11-15 BC-8). The listing
# is now waited for. held_store_fail makes every listing fail first:
#   2. the peer's bits survive with every bitmap block through that path.
#
# DISCRIMINATION: bitmap_writeback=1 (bitmaps dirty, as before): 1 fails;
# held_store_fallback_dirty=1 (the old fallback): 2 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in stop_sweep_delay_ms bitmap_writeback hb_maint_delay_ms held_store_fail held_store_fallback_dirty; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NODE_POKE="$(ct_helper node_poke)"
MAP="$(ct_helper bg_map)"
BG_POKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt fwr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set stop_sweep_delay_ms 0
ct_param_set bitmap_writeback 0
ct_param_set held_store_fail 0
ct_param_set held_store_fallback_dirty 0
ct_param_set hb_maint_delay_ms 0
compress_timing

# <0: held | 1: bitmap_writeback | s: listing fails, waited | d: listing fails, old dirty fallback>
#   -> "staged=<..> fenced=<0|1> early=<0|1> got=<hex> retried=<n>"
round() {
    local dev back lba mark wpid go got retried r0 fenced=0 early=1
    dev="$(ct_dev 560 "fwr$1-$RANDOM")"
    back="$(losetup -l -n -O BACK-FILE "$dev" | tr -d ' ')"
    ct_mkfs_small "$dev" >/dev/null
    # Group 0's data bitmap: start + off_data_bmap (the alignment gap
    # sits before the bitmap, not after the header).
    lba=$(($("$MAP" "$dev" | awk '$1 == "bg" && $2 == 0 {split($4,a,"="); print a[2]}') +
        $("$BG_POKE" "$dev" 0 --dump | sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p')))
    case "$1" in
    1) echo 1 >/sys/module/cetrafs/parameters/bitmap_writeback ;;
    s) echo 1 >/sys/module/cetrafs/parameters/held_store_fail ;;
    d) echo 1 >/sys/module/cetrafs/parameters/held_store_fail
       echo 1 >/sys/module/cetrafs/parameters/held_store_fallback_dirty ;;
    esac
    # The heartbeat's maintenance pass writes held (and other) bitmap
    # blocks; held off for the round, so the only writers of the bitmap
    # are the ones under test. The lease is renewed by separate work, so
    # the fence is still seen.
    echo 20000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    ct_mount "$dev" "$MNT"
    r0="$(sed -n 's/^held_store_retries: //p' "$(ct_procdir "$dev")/info")"
    rd8() { python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(os.pread(fd, 8, int(sys.argv[2]) * 4096 + int(sys.argv[3])).hex())" "$back" "$lba" "$1"; }
    go="$(ct_tmp "fwr-go$1")"
    rm -f "$go"
    python3 -I - "$MNT/f" "$go" <<'PY' &
import os, sys, time, mmap
# O_DIRECT: the blocks are allocated by the write itself -- buffered,
# they were allocated at writeback, whenever that came, and the bitmap
# was clean at the fence in about half the runs
buf = mmap.mmap(-1, 1 << 20)
buf.write(b"x" * (1 << 20))
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY | os.O_DIRECT, 0o644)
os.write(fd, buf)
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
os.close(fd)
PY
    wpid=$!
    sleep 1
    if [ "$(rd8 8)" != 0000000000000000 ]; then
        : >"$go"; wait "$wpid" || true; echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
        echo 0 >/sys/module/cetrafs/parameters/held_store_fail; echo 0 >/sys/module/cetrafs/parameters/held_store_fallback_dirty
        echo 0 >/sys/module/cetrafs/parameters/bitmap_writeback
        ct_umount "$MNT"
        echo "staged=no-bits-already-on-device"; return
    fi
    retried=$(($(sed -n 's/^held_store_retries: //p' "$(ct_procdir "$dev")/info") - r0))
    echo 6000 >/sys/module/cetrafs/parameters/stop_sweep_delay_ms
    mark="$(dmesg_mark)"
    "$NODE_POKE" "$dev" 0 --bump-fence 1 >/dev/null
    wait_for 15 "dmesg_since '$mark' | grep -q SELF-FENCED" && fenced=1
    # the peer, owning the Zone Group now, allocates in the same bitmap block
    python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b'\xff' * 8, int(sys.argv[2]) * 4096 + 512)
os.fsync(fd)" "$back" "$lba"
    # the block layer writes what it holds dirty -- no filesystem involved
    python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)" "$dev"
    dmesg_since "$mark" | grep -q "discarded .* dirty metadata" || early=0
    wait_for 15 "dmesg_since '$mark' | grep -q 'discarded .* dirty metadata'" || true
    echo 0 >/sys/module/cetrafs/parameters/stop_sweep_delay_ms
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    echo 0 >/sys/module/cetrafs/parameters/held_store_fail
    echo 0 >/sys/module/cetrafs/parameters/held_store_fallback_dirty
    echo 0 >/sys/module/cetrafs/parameters/bitmap_writeback
    : >"$go"
    wait "$wpid" || true
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    got="$(rd8 512)"
    echo "staged=yes fenced=$fenced early=$early got=$got retried=${retried:-0}"
}

get() { sed -n "s/.*$1=\([0-9a-z-]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "held bitmaps: $R"
# The control has only to show the window is reachable; what the flusher
# has already written by the fence varies run to run, so it gets three
# fresh images to show it in.
for try in 1 2 3; do
    C="$(round "1" | sed "s/^/try=$try /")"
    log "control (dirty bitmaps): $C"
    [ "$(get got "$C")" != ffffffffffffffff ] && break
done
for v in "$R" "$C"; do
    [ "$(get staged "$v")" = yes ] && [ "$(get fenced "$v")" = 1 ] && [ "$(get early "$v")" = 0 ] ||
        { fail "setup: not staged, fenced, and fsynced before the sweep ($v)"; ct_exit; }
done
pass "setup: bits only in memory; fenced; the device fsynced before the sweep ran"
[ "$(get got "$R")" = ffffffffffffffff ] && pass "1: the peer's allocations survived the device fsync" ||
    fail "1: block-layer writeback put the fenced node's bitmap over the peer's (now $(get got "$R"))"
[ "$(get got "$C")" != ffffffffffffffff ] && pass "control: dirty bitmaps reached the device through the fsync ($(get got "$C"))" ||
    fail "control: dirty bitmaps did not reach the device -- the suite does not reach the window"

R2="$(round s)"
log "listing failed, waited for: $R2"
for try in 1 2 3; do
    C2="$(round d | sed "s/^/try=$try /")"
    log "control (old dirty fallback): $C2"
    [ "$(get got "$C2")" != ffffffffffffffff ] && break
done
for v in "$R2" "$C2"; do
    [ "$(get staged "$v")" = yes ] && [ "$(get fenced "$v")" = 1 ] && [ "$(get early "$v")" = 0 ] ||
        { fail "setup B: not staged, fenced, and fsynced before the sweep ($v)"; ct_exit; }
done
[ "$(get retried "$R2")" -gt 0 ] 2>/dev/null || { fail "setup B: no listing went through the failure path ($R2)"; ct_exit; }
pass "setup B: listings failed and were retried; fenced; fsynced before the sweep"
[ "$(get got "$R2")" = ffffffffffffffff ] && pass "2: the peer's allocations survived with the listings failing" ||
    fail "2: a bitmap the list could not take reached the device after the fence (now $(get got "$R2"))"
[ "$(get got "$C2")" != ffffffffffffffff ] &&
    pass "control: the old dirty fallback put the bitmap on the device through the fsync ($(get got "$C2"))" ||
    fail "control: the fallback's bitmap did not reach the device -- the suite does not reach it"

# The other half: a block that went through the failing listing is still
# WRITTEN by a live boundary -- round s alone would pass if the listing
# dropped it, since a fenced node writes nothing anyway.
live() {
    local dev back lba r0 r1 got
    dev="$(ct_dev 560 "fwrl-$RANDOM")"
    back="$(losetup -l -n -O BACK-FILE "$dev" | tr -d ' ')"
    ct_mkfs_small "$dev" >/dev/null
    lba=$(($("$MAP" "$dev" | awk '$1 == "bg" && $2 == 0 {split($4,a,"="); print a[2]}') +
        $("$BG_POKE" "$dev" 0 --dump | sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p')))
    ct_mount "$dev" "$MNT"
    r0="$(sed -n 's/^held_store_retries: //p' "$(ct_procdir "$dev")/info")"
    echo 1 >/sys/module/cetrafs/parameters/held_store_fail
    python3 -I -c '
import os, sys, mmap
buf = mmap.mmap(-1, 1 << 20); buf.write(b"x" * (1 << 20))
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY | os.O_DIRECT, 0o644)
os.write(fd, buf); os.fsync(fd); os.close(fd)' "$MNT/f"
    echo 0 >/sys/module/cetrafs/parameters/held_store_fail
    sync -f "$MNT"
    r1="$(sed -n 's/^held_store_retries: //p' "$(ct_procdir "$dev")/info")"
    got="$(python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(os.pread(fd, 8, int(sys.argv[2]) * 4096 + 8).hex())" "$back" "$lba")"
    ct_umount "$MNT"
    echo "retried=$((r1 - r0)) got=$got"
}
L="$(live)"
log "live, listings failing: $L"
[ "$(get retried "$L")" -gt 0 ] 2>/dev/null && [ "$(get got "$L")" != 0000000000000000 ] &&
    pass "3: a block listed through the failure path was written by the live boundary" ||
    fail "3: the listing failed and the bitmap never reached the device, or nothing went through it ($L)"
ct_exit
