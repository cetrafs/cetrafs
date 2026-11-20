#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held block whose listing stopped the mount leaves no held flag behind for the next mount
#
# A held (gate-written) bitmap block that cannot be listed twice stops
# the mount (audit BC-8). It used to keep its held flag and the list's
# pin, which no list held and so nothing at unmount dropped: with the
# device kept open the buffer outlived the mount, the next mount's first
# update of that block found the flag already set, never listed it, and
# no gated flush ever wrote it -- blocks in use, marked free on the
# device (audit F-74).
# Staged on one node, the loop device held open across the remount:
#   setup: the mount stopped over a block it could not list, and the
#          remount wrote a file;
#   1. fsck finds no block in use but marked free.
#
# DISCRIMINATION: held_store_fatal_keep=1 -- the flag and pin stay, and
# fsck finds the remount's blocks marked free.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in held_store_fail held_store_fail_twice held_store_fatal_keep; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt hss)"
ct_track mnt "$MNT"
ct_param_set held_store_fail 0
ct_param_set held_store_fail_twice 0
ct_param_set held_store_fatal_keep 0
P=/sys/module/cetrafs/parameters

# <keep 0|1> -> "stopped= wrote= free="
round() {
    local img dev mark stopped=0 wrote=0 free=0 hold o
    img="$(ct_image 560 "hss$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    exec {hold}<"$dev" # the device stays open: the page cache outlives the mount
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/a" bs=64k count=4 conv=fsync status=none
    echo "$1" >$P/held_store_fatal_keep
    mark="$(dmesg_mark)"
    echo 1 >$P/held_store_fail_twice
    echo 1 >$P/held_store_fail
    dd if=/dev/urandom of="$MNT/b" bs=64k count=4 conv=fsync status=none 2>/dev/null || true
    echo 0 >$P/held_store_fail
    echo 0 >$P/held_store_fail_twice
    dmesg_since "$mark" | grep -q "could not be listed for its gated write" && stopped=1
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/held_store_fatal_keep
    if ct_mount "$dev" "$MNT" 2>/dev/null; then
        dd if=/dev/urandom of="$MNT/c" bs=64k count=4 conv=fsync status=none && wrote=1
        sync
        umount "$MNT" || umount -l "$MNT"
    fi
    exec {hold}<&-
    o="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q "in use but marked free" <<<"$o" && free=1
    grep -m3 "^ERR" <<<"$o" >&2 || true
    echo "stopped=$stopped wrote=$wrote free=$free"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "dropped: $R"
C="$(round 1)"
log "control (kept): $C"
for v in "$R" "$C"; do
    [ "$(get stopped "$v")" = 1 ] && [ "$(get wrote "$v")" = 1 ] ||
        { fail "setup: the mount did not stop over the listing, or the remount wrote nothing ($v)"; ct_exit; }
done
pass "setup: the mount stopped over a block it could not list, and the remount wrote a file"
[ "$(get free "$R")" = 0 ] && pass "1: no block in use is marked free after the remount" ||
    fail "1: the remount's blocks are marked free on the device ($R)"
[ "$(get free "$C")" = 1 ] && pass "control: with the flag kept, the remount never wrote its bitmap" ||
    fail "control: nothing marked free -- the suite does not reach the stale flag ($C)"
ct_exit
