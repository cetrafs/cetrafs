#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# removing an entry from a directory whose size was mis-counted does not wrap its size
#
# An unlink takes one entry's bytes off the directory's size with no
# floor: a size already below that -- a lost staged publish, a peer's
# damage -- wrapped to nearly 2^64 and read back as corrupt from then on
# (audit 2026-11-14 N4). It is now held at 0 and the kernel says so.
#
# The directory's on-disk size is set to 0 with an entry in it; the
# entry is removed; the size must read 0 and the directory stay usable.
#
# DISCRIMINATION: dir_size_no_floor decrements as before; the size then
# wraps.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_size_no_floor ] || { skip "dir_size_no_floor is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt dsf)"
ct_track mnt "$MNT"
ct_param_set dir_size_no_floor 0

# <no_floor 0|1> -> "<on-disk size after the unlink> <create afterwards: ok|fail>"
probe() {
    local img dev ino size c
    img="$(ct_image 560 "dsf$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    : >"$MNT/d/a"
    sync
    ino="$(stat -c %i "$MNT/d")"
    ct_umount "$MNT"
    "$IPOKE" "$img" setsize "$ino" 0 >/dev/null
    ct_mount "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/dir_size_no_floor
    rm -f "$MNT/d/a" || true
    echo 0 >/sys/module/cetrafs/parameters/dir_size_no_floor
    : 2>/dev/null >"$MNT/d/b" && c=ok || c=fail
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    size="$("$IPOKE" "$img" size "$ino" | grep -o '[0-9]*' | tail -1)"
    echo "$size $c"
}
read -r S C <<<"$(probe 0)"
log "after the unlink: size $S, a later create: $C"
[ "$S" -lt 4096 ] && pass "the directory's size did not wrap ($S)" || fail "the directory's size wrapped to $S"
[ "$C" = ok ] && pass "and the directory still takes a create" || fail "the directory refuses a create after the unlink"
read -r S0 C0 <<<"$(probe 1)"
# A wrapped size is past what [ -gt ] can parse: compare digit counts.
[ "${#S0}" -gt 10 ] && pass "control: without the floor the size wraps to $S0 -- the suite discriminates" ||
    fail "control: without the floor the size is $S0 -- the suite cannot tell"
ct_exit
