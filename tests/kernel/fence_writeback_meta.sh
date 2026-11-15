#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# block-layer writeback never puts a fenced node's in-place metadata update on the device
#
# An in-place metadata update -- a record, a dirent or xattr block, a
# journal block -- was published to the cache DIRTY and written by its
# caller straight after. A node frozen between the two resumed with the
# block dirty, and once fenced its refused write left it dirty until the
# queued sweep ran: either way the block layer's own writeback could put
# the image on the device after the lease was gone, over what a peer had
# written there since (audit 2026-11-15 A-15). The update is now HELD,
# as allocation bitmaps are (fence_writeback_race.sh), and only
# cetrafs's gated writes put it on the device.
#
# A create's record write is stalled between its cache publish and its
# write (record_publish_stall_ms); the node is fenced there, the peer --
# played on the device, as in fence_writeback_race.sh -- writes that
# record, and an fsync of the block device asks the block layer to write
# whatever it holds dirty, before the sweep (stop_sweep_delay_ms):
#   setup: the write stalled; fenced; fsynced before the sweep;
#   1. the peer's record survives.
#
# DISCRIMINATION: meta_writeback=1 (updates left dirty, as before): the
# fsync writes this node's record over the peer's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in stop_sweep_delay_ms meta_writeback hb_maint_delay_ms record_publish_stall_ms record_publish_stall_ino; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NODE_POKE="$(ct_helper node_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt fwm)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set stop_sweep_delay_ms 0
ct_param_set meta_writeback 0
ct_param_set hb_maint_delay_ms 0
ct_param_set record_publish_stall_ms 0
ct_param_set record_publish_stall_ino 0
compress_timing

# <meta_writeback 0|1> -> "stalled=<ino> fenced=<0|1> early=<0|1> owner=<n>"
round() {
    local dev back mark tpid ino fenced=0 early=1 owner
    dev="$(ct_dev 560 "fwm$1-$RANDOM")"
    back="$(losetup -l -n -O BACK-FILE "$dev" | tr -d ' ')"
    ct_mkfs_small "$dev" >/dev/null
    echo "$1" >$P/meta_writeback
    # the tick's held flush stays out of the window (fence_writeback_race.sh)
    echo 20000 >$P/hb_maint_delay_ms
    ct_mount "$dev" "$MNT"
    echo x >"$MNT/f"
    sync
    mark="$(dmesg_mark)"
    echo 6000 >$P/record_publish_stall_ms
    touch "$MNT/g" 2>/dev/null &
    tpid=$!
    wait_for 5 "dmesg_since '$mark' | grep -q 'TEST: record write of ino'" || true
    ino="$(dmesg_since "$mark" | sed -n 's/.*TEST: record write of ino \([0-9]*\) stalled.*/\1/p' | head -1)"
    if [ -z "$ino" ]; then
        echo 0 >$P/record_publish_stall_ms; wait "$tpid" || true
        echo 0 >$P/hb_maint_delay_ms; echo 0 >$P/meta_writeback; ct_umount "$MNT"
        echo "stalled=none"; return
    fi
    echo 9000 >$P/stop_sweep_delay_ms
    "$NODE_POKE" "$dev" 0 --bump-fence 1 >/dev/null
    wait_for 5 "dmesg_since '$mark' | grep -q SELF-FENCED" && fenced=1
    # the peer writes that record on the device
    "$LOCK_POKE" "$back" "$ino" 5 1 >/dev/null
    # the block layer writes what it holds dirty -- no filesystem involved
    python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)" "$dev"
    dmesg_since "$mark" | grep -q "discarded .* dirty metadata" || early=0
    wait "$tpid" || true # the stall ends, the write is refused
    python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)" "$dev"
    wait_for 15 "dmesg_since '$mark' | grep -q 'discarded .* dirty metadata\|SELF-FENCED: discarded'" || true
    echo 0 >$P/stop_sweep_delay_ms
    echo 0 >$P/hb_maint_delay_ms
    echo 0 >$P/meta_writeback
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    owner="$("$LOCK_POKE" "$back" "$ino" | grep -o '\bowner=[0-9]*' | cut -d= -f2)"
    echo "stalled=$ino fenced=$fenced early=$early owner=$owner"
}

get() { sed -n "s/.*$1=\([0-9a-z-]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "held updates: $R"
C="$(round 1)"
log "control (updates left dirty): $C"
for v in "$R" "$C"; do
    [ "$(get stalled "$v")" != none ] && [ "$(get fenced "$v")" = 1 ] && [ "$(get early "$v")" = 0 ] ||
        { fail "setup: not stalled, fenced, and fsynced before the sweep ($v)"; ct_exit; }
done
pass "setup: a record write stalled after its cache publish; fenced; the device fsynced before the sweep"
[ "$(get owner "$R")" = 5 ] && pass "1: the peer's record survived the device fsync" ||
    fail "1: block-layer writeback put the fenced node's record over the peer's ($R)"
[ "$(get owner "$C")" != 5 ] && pass "control: a dirty record reached the device through the fsync ($C)" ||
    fail "control: the dirty record did not reach the device -- the suite does not reach the window ($C)"
ct_exit
