#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck walks a tree block its tree names twice only once
#
# fsck's extent-tree walker (userspace/extwalk.h) had no visited set,
# where the kernel's has one: index entries naming one child many times
# multiplied the walk below them -- three blocks of a depth-3 tree
# describe 65.5M extents, every name re-read and re-marked, and a
# directory's flattened map grew toward a GiB (audit 2026-11-22 N-9). It
# now walks each block once and reports the rest as references.
#
# tree_share_poke gives a regular file a depth-3 tree of three blocks: a
# leaf of 254 one-block extents, an interior naming it 254 times, a top
# interior naming that 254 times (16.4M extents named).
#   1. fsck reads each of the three tree blocks once;
#   2. it still names the shared leaf as referenced more than once.
#
# DISCRIMINATION: CETRAFS_FSCK_TEST_WALK_NO_DEDUP=1 (the walk as before),
# on a top interior naming its child 20 times (254 times runs fsck out
# of memory): every name is read -- 1 + 20 + 20 * 254 block reads.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }
TSP="$(ct_helper tree_share_poke)"
MNT="$(ct_mnt ftsc)"
ct_track mnt "$MNT"

# plant <tag> <k> -> DEV P INO: a regular file given the shared tree
plant() {
    local img nx
    img="$(ct_image 2048 "ftsc$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs "$DEV" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/blocks" bs=4096 count=260 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=1 conv=fsync status=none
    truncate -s $((508 * 4096)) "$MNT/f"
    P="$(filefrag -v -b4096 "$MNT/blocks" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }')"
    nx="$(filefrag "$MNT/blocks" | grep -o '[0-9]* extent' | cut -d' ' -f1)"
    INO="$(stat -c %i "$MNT/f")"
    rm "$MNT/blocks" # the blocks are borrowed by address only
    sync
    ct_umount "$MNT"
    [ -n "$P" ] && [ "$P" -gt 0 ] && [ "$nx" = 1 ] || { fail "setup: no contiguous run to borrow ($P, $nx extents)"; ct_exit; }
    TREE_SHARE_STRIDE=1 "$TSP" "$img" "$INO" "$P" $((P + 1)) $((P + 2)) "$2" $((P + 3)) >/dev/null ||
        { fail "setup: the shared tree was not planted"; ct_exit; }
    blockdev --flushbufs "$DEV"
}

# <no_dedup 0|1> -> "reads=<n> secs=<n> named=<yes|no>"
probe() {
    local out t0 t1 reads named=no
    t0=$SECONDS
    out="$(CETRAFS_FSCK_TEST_TREE_READS=1 CETRAFS_FSCK_TEST_WALK_NO_DEDUP="$1" "$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
    t1=$SECONDS
    reads="$(sed -n 's/^fsck: extent tree blocks read: //p' <<<"$out" | tail -1)"
    grep -q "^ERR: block $((P + 2)) is referenced by more than one inode (inode $INO among them)" <<<"$out" && named=yes
    echo "reads=${reads:-none} secs=$((t1 - t0)) named=$named"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2; }

plant f 254
R="$(probe 0)"
log "walked once: $R"
plant c 20 # every name of 254 runs fsck out of memory: that was the bug
C="$(probe 1)"
log "control (every name): $C"
[ "$(get reads "$R")" != none ] || { fail "setup: fsck printed no read count: $R"; ct_exit; }
[ "$(get reads "$R")" -le 3 ] && pass "1: fsck read the three tree blocks once ($(get reads "$R") reads, $(get secs "$R") s)" ||
    fail "1: $R"
[ "$(get named "$R")" = yes ] && pass "2: fsck names the shared leaf as referenced more than once" || fail "2: $R"
[ "$(get reads "$C")" -ge $((20 * 254)) ] && [ "$(get named "$C")" = yes ] &&
    pass "control: walking every name read $(get reads "$C") blocks in $(get secs "$C") s" ||
    fail "control: $C -- the walk does not reach the shared blocks"
ct_exit
