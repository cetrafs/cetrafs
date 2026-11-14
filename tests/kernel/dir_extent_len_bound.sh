#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory whose extents name more blocks than a directory may hold is refused, not scanned
#
# Every directory scan -- lookup, readdir, create, unlink -- reads each
# of its blocks forced-fresh under the namespace lock, and the only
# bound on how many was that the extent lie inside the data area. A
# record (corrupt, or written by a hostile peer) with a 2^31-block
# extent made one create read that many blocks, uninterruptibly, holding
# the directory's cluster lock (audit 2026-11-14 RT-3). A directory now
# never grows past CETRAFS_DIR_MAX_BLOCKS (2^18), a record naming more
# is damage, and every scan loop answers a fatal signal.
#
# A directory's inline extent is set to 300,000 blocks, inside the data
# area of a 2 GiB volume (the address check passes); a lookup in it must
# be refused as damage, with the count named.
#
# The killable half is not observable here: an over-long run of VALID
# dirent blocks cannot be planted on a loop volume in reasonable time.
#
# DISCRIMINATION: dir_len_unbounded lifts the cap; the same lookup is
# then not refused by the count (it scans until the first unreadable
# block instead).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_len_unbounded ] || { skip "dir_len_unbounded is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt delb)"
ct_track mnt "$MNT"
ct_param_set dir_len_unbounded 0

# <unbounded 0|1> -> "<errno of the lookup> <count named in dmesg: yes|no>"
probe() {
    local img dev ino mark rc
    img="$(ct_image 2048 "delb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    : >"$MNT/d/a"
    sync
    ino="$(stat -c %i "$MNT/d")"
    ct_umount "$MNT"
    "$IPOKE" "$img" extset "$ino" 0 len 300000 >/dev/null
    echo "$1" >/sys/module/cetrafs/parameters/dir_len_unbounded
    ct_mount "$dev" "$MNT"
    mark="$(dmesg_mark)"
    rc="$(python3 -c '
import os, sys
try:
    os.stat(sys.argv[1]); print(0)
except OSError as e:
    print(e.errno)' "$MNT/d/nonexistent-name")"
    echo 0 >/sys/module/cetrafs/parameters/dir_len_unbounded
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    dmesg_since "$mark" | grep -q "more than a directory may hold" && echo "$rc yes" || echo "$rc no"
}
read -r E NAMED <<<"$(probe 0)"
log "lookup in the over-long directory: errno $E, count named: $NAMED"
[ "$E" = 117 ] && [ "$NAMED" = yes ] && pass "a directory naming 300,000 blocks is refused as damage (EUCLEAN), the count named" ||
    fail "the over-long directory was not refused by its count (errno $E, named: $NAMED)"
read -r E0 NAMED0 <<<"$(probe 1)"
[ "$NAMED0" = no ] && pass "control: with the cap lifted the count refuses nothing (errno $E0) -- the suite discriminates" ||
    fail "control: the cap still refused it -- the suite cannot tell"
ct_exit
