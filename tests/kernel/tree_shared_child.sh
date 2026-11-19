#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tree walk walks a block its tree names twice only once
#
# No healthy extent tree names one block twice, but nothing on the disk
# prevents it, and depth-3 interiors that share their children let three
# blocks describe 65.5M extents. Every whole-tree walk -- fiemap and
# SEEK's flatten, evict's free set, the scrub's reference set -- then did
# 65.5M extents' work, and a flatten kvmalloc'd a GiB for it (audit
# 2026-11-15 F-62). cetrafs_tree_walk() now walks each block once.
#
# tree_share_poke gives a regular file a depth-3 tree of three blocks: a
# leaf of 254 one-block extents (distinct addresses), an interior naming
# it 254 times, a top interior naming that k times.
#   setup: the tree is planted;
#   1. k=254 (16.4M extents named): filefrag lists the 254 real extents
#      (every other block), SEEK_HOLE from 0 answers block 1 and
#      SEEK_DATA from there block 2, within seconds;
#   2. the walk said so: tree_shared_skips moved, dmesg names the block;
#   3. fsck names the shared leaf as referenced more than once.
#
# DISCRIMINATION: tree_walk_no_dedup=1 (k=20, 1.29M extents, so the
# control stays cheap) walks every name: tree_shared_skips does not move
# and nothing is named. fiemap's answer is the same either way (its
# cursor skips the repeats), so the observable is the walk's own count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/tree_walk_no_dedup ] || { skip "tree_walk_no_dedup is missing"; ct_exit; }
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }
TSP="$(ct_helper tree_share_poke)"
FSCKOUT="$(ct_tmp tsc-fsck)"
MNT="$(ct_mnt tsc)"
ct_track mnt "$MNT"
ct_param_set tree_walk_no_dedup 0

# The first hole from block 0, then the next data from there.
seek_pair() {
    python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
h = os.lseek(fd, 0, os.SEEK_HOLE)
print("%d/%d" % (h // 4096, os.lseek(fd, h, os.SEEK_DATA) // 4096))' "$1"
}

# probe <k> <no_dedup 0|1> -> "<fiemap extents> <hole/data> <secs> <skips moved> <named> <fsck names the leaf>"
probe() {
    local img dev ino p mark s0 s1 t0 t1 nx h named
    img="$(ct_image 2048 "tsc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/blocks" bs=4096 count=260 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=1 conv=fsync status=none
    truncate -s $((508 * 4096)) "$MNT/f"
    p="$(filefrag -v -b4096 "$MNT/blocks" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }')"
    nx="$(filefrag "$MNT/blocks" | grep -o '[0-9]* extent' | cut -d' ' -f1)"
    ino="$(stat -c %i "$MNT/f")"
    rm "$MNT/blocks" # the blocks are borrowed by address only
    sync
    ct_umount "$MNT"
    [ -n "$p" ] && [ "$p" -gt 0 ] && [ "$nx" = 1 ] || { echo "setup-noblocks"; return; }
    TREE_SHARE_STRIDE=1 "$TSP" "$img" "$ino" "$p" $((p + 1)) $((p + 2)) "$1" $((p + 3)) >&2 || { echo "setup-poke"; return; }
    "$ROOT/userspace/fsck.cetra" "$dev" >"$FSCKOUT" 2>&1 || true
    frc=no
    grep -q "^ERR: block $((p + 2)) is referenced by more than one inode (inode $ino among them)" "$FSCKOUT" && frc=yes
    echo "$2" >/sys/module/cetrafs/parameters/tree_walk_no_dedup
    ct_mount "$dev" "$MNT"
    mark="$(dmesg_mark)"
    s0="$(sed -n 's/^tree_shared_skips: //p' "$(ct_procdir "$dev")/info")"
    t0=$(date +%s)
    nx="$(filefrag -v -b4096 "$MNT/f" | awk -F: '$1 ~ /^ *[0-9]+$/' | wc -l)"
    h="$(seek_pair "$MNT/f")"
    t1=$(date +%s)
    s1="$(sed -n 's/^tree_shared_skips: //p' "$(ct_procdir "$dev")/info")"
    echo 0 >/sys/module/cetrafs/parameters/tree_walk_no_dedup
    named=no
    dmesg_since "$mark" | grep -q "names block $((p + 1)) twice" && named=yes
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo "$nx $h $((t1 - t0)) $([ "$s1" -gt "$s0" ] && echo yes || echo no) $named $frc"
}

read -r NX H SECS MOVED NAMED FRC <<<"$(probe 254 0)"
case "$NX" in setup-*) fail "setup: $NX"; ct_exit ;; esac
pass "setup: a regular file's three-block tree names 16,387,064 extents"
log "k=254: fiemap $NX extents, hole/data $H, ${SECS}s, skips moved: $MOVED, named: $NAMED, fsck: $FRC"
[ "$NX" = 254 ] && [ "$H" = 1/2 ] && pass "1: fiemap lists the 254 real extents; SEEK_HOLE/SEEK_DATA answer 1/2" ||
    fail "1: fiemap $NX extents, hole/data $H"
[ "$SECS" -le 5 ] && pass "1: in ${SECS}s" || fail "1: ${SECS}s -- the walk went through every name"
[ "$MOVED" = yes ] && [ "$NAMED" = yes ] && pass "2: the walk skipped the repeats and named the block" ||
    fail "2: skips moved: $MOVED, block named: $NAMED"
[ "$FRC" = yes ] && pass "3: fsck reports the shared leaf as referenced more than once" ||
    fail "3: fsck does not name the shared leaf: $(grep -m1 '^ERR' "$FSCKOUT" || echo clean)"

read -r NX H SECS MOVED NAMED FRC <<<"$(probe 20 1)"
case "$NX" in setup-*) fail "control setup: $NX"; ct_exit ;; esac
[ "$MOVED" = no ] && [ "$NAMED" = no ] &&
    pass "control: without the dedup every name is walked (nothing skipped, nothing named)" ||
    fail "control: skips moved: $MOVED, named: $NAMED -- the suite cannot tell"
ct_exit
