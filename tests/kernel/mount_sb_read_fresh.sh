#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount reads block 0 from the device, not from a cached copy older than a reformat
#
# fill_super read the superblock with sb_bread(): a copy cached before
# the volume was reformatted through another path -- another host on a
# shared LUN, another device over the same storage -- was taken as the
# volume, and the registry write that follows was aimed by the old
# layout before the post-registration re-check refused the mount (audit
# 2026-11-22 N-63). The first read is forced fresh now.
#
# Two loop devices over one image stand for two hosts: block 0 is read
# through A with a descriptor held open (its cache keeps the page), the
# volume is reformatted through B with a different Zone Group count, and
# A is mounted:
#   1. the mount comes up, on the NEW layout (its Zone Group count).
#
# DISCRIMINATION: sb_first_read_cached=1 (as before): the mount takes
# the cached old superblock -- refused by the re-check, or up on the old
# layout.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/sb_first_read_cached ] || { skip "sb_first_read_cached is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt sbfresh)"
ct_track mnt "$MNT"
ct_param_set sb_first_read_cached 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <cached 0|1> -> RES "mounted=<0|1> zgs=<n>"
round() {
    local img a b holder rc=0 zgs=none
    img="$(ct_image 1200 "sbf$1")"
    a="$(ct_loop "$img")"
    b="$(ct_loop "$img")"
    ct_mkfs "$a" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    # Hold A open with block 0 read through its cache.
    python3 -I -c '
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
os.pread(fd, 4096, 0)
open(sys.argv[2], "w").close()
time.sleep(120)' "$a" "$img.held" &
    holder=$!
    wait_for 10 "[ -e '$img.held' ]" || { fail "setup: the holder never read block 0"; ct_exit; }
    ct_track file "$img.held"
    # The reformat, through the other device: two Zone Groups now.
    ct_mkfs "$b" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    losetup -d "$b" 2>/dev/null || true
    echo "$2" >$P/sb_first_read_cached
    mount -t cetrafs "$a" "$MNT" 2>/dev/null || rc=$?
    echo 0 >$P/sb_first_read_cached
    if [ "$rc" = 0 ]; then
        zgs="$(awk '$1 == "zone_group_count:" { print $2 }' "$(ct_procdir "$a")/info")"
        umount "$MNT" 2>/dev/null || umount -l "$MNT"
    fi
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    RES="mounted=$([ "$rc" = 0 ] && echo 1 || echo 0) zgs=$zgs"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (first read cached): $C"
[ "$(get mounted "$R")" = 1 ] && [ "$(get zgs "$R")" = 2 ] &&
    pass "1: the mount read the reformatted volume's superblock: up, with its 2 Zone Groups" || fail "1: $R"
{ [ "$(get mounted "$C")" = 0 ] || [ "$(get zgs "$C")" = 1 ]; } &&
    pass "control: from the cache, the mount took the old superblock ($C)" ||
    fail "control: $C -- the cache did not hold the old block 0, the suite proves nothing"
ct_exit
