#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace release whose lock was stolen does not publish the directory's file sector
#
# A create that grows a directory stages its record update for the
# namespace lock's release, which writes the file sector -- size, extent
# root -- first and then swaps the namespace sector to clear the lock.
# Only that swap noticed a lock stolen meanwhile: the file sector had
# already gone out, over whatever the peer that took the lock had
# written (audit 2026-11-14 L-F2). The release now reads the namespace
# sector fresh before the file-sector write and forfeits the staged
# update if the lock is no longer its own.
#
# One node plays the peer: the release is held (nslock_release_stall_ms)
# while the directory's lock is rewritten on the device to another
# node. The create grows the directory into a new block, so its staged
# update carries a new size; that size must not reach the device.
#
# DISCRIMINATION: nslock_fd_precheck_off writes the file sector without
# the check; the grown size then lands under the stolen lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in nslock_fd_precheck_off nslock_release_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt nsfs)"
ct_track mnt "$MNT"
ct_param_set nslock_fd_precheck_off 0
ct_param_set nslock_release_stall_ms 0
P=/sys/module/cetrafs/parameters
dsize() { "$LPOKE" "$1" --rec "$2" | sed -n 's/^size=\([0-9]*\) .*/\1/p'; }

# <precheck_off 0|1> -> "<size before> <size on the device after the stolen release>"
probe() {
    local dev c i ino before after
    dev="$(ct_loop "$(ct_image 560 "nsfs$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    # How many names fill the directory's first block: create until it grows.
    mkdir "$MNT/probe" "$MNT/d"
    c=0
    while [ "$(stat -c %s "$MNT/probe")" = "$(stat -c %s "$MNT/d")" ] && [ "$c" -lt 2000 ]; do
        c=$((c + 1))
        : >"$MNT/probe/name-$(printf %05d "$c")"
    done
    for i in $(seq 1 $((c - 1))); do : >"$MNT/d/name-$(printf %05d "$i")"; done
    sync
    ino="$(stat -c %i "$MNT/d")"
    before="$(dsize "$dev" "$ino")"
    echo "$1" >$P/nslock_fd_precheck_off
    echo 3000 >$P/nslock_release_stall_ms
    : >"$MNT/d/name-$(printf %05d "$c")" &
    sleep 1.5
    "$LPOKE" "$dev" "$ino" --ns 7 >/dev/null # a peer takes the lock while the release is held
    wait || true
    echo 0 >$P/nslock_release_stall_ms
    echo 0 >$P/nslock_fd_precheck_off
    after="$(dsize "$dev" "$ino")"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo "$before $after $c"
}
read -r B A C <<<"$(probe 0)"
log "directory size on the device: $B before, $A after the stolen release ($C names fill a block)"
[ -n "$B" ] && [ "$C" -lt 2000 ] || { fail "setup: could not size the directory (before=$B, names=$C)"; ct_exit; }
[ "$A" = "$B" ] && pass "the stolen release left the directory's file sector alone" ||
    fail "the release wrote the directory's size ($A, was $B) under a lock a peer held"
read -r B0 A0 C0 <<<"$(probe 1)"
[ "$A0" != "$B0" ] && pass "control: without the check the grown size lands under the stolen lock ($B0 -> $A0) -- the suite discriminates" ||
    fail "control: the size did not move without the check either ($B0) -- the suite cannot tell"
ct_exit
