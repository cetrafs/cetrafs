#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory's extent tree is refused by its extent count while it is walked, not after the copy
#
# A directory never holds more than CETRAFS_DIR_MAX_BLOCKS (2^18) blocks,
# and every scan refused a record naming more -- but only after
# flattening the whole tree into one array and sorting it. Depth 3 lets a
# tree describe 65.5M extents, and interior blocks that share their
# children describe them with three blocks: a lookup or an ls then
# allocated up to a GiB (GFP_NOFS) and sorted it with no reschedule
# (audit 2026-11-15 F-62). The flatten now stops at the cap.
#
# tree_share_poke gives a directory a depth-3 tree of three blocks: a
# leaf of 254 extents, an interior naming it 254 times, a top interior
# naming that k times. A tree walk now visits a shared block once, which
# defuses this tree on its own; tree_walk_no_dedup takes that away so the
# cap is tested alone -- it is what bounds a directory whose 2^18 + 1
# extents are all real.
#   setup: the tree is planted (the helper reports the extent count);
#   1. k=254 (16.4M extents): a lookup fails EUCLEAN at once, the flatten
#      cap named in dmesg; ls fails the same way;
#   2. another directory still lists.
#
# DISCRIMINATION: dir_flatten_unbounded=1 (k=5, 322,580 extents, so the
# control stays cheap) flattens the whole tree, and only the count after
# the copy refuses it: the flatten cap is not named.
# What this cannot see: the memory itself. The cap's message is the
# observable; the control shows that without it the copy is made.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_flatten_unbounded ] || { skip "dir_flatten_unbounded is missing"; ct_exit; }
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }
TSP="$(ct_helper tree_share_poke)"
MNT="$(ct_mnt dtfb)"
ct_track mnt "$MNT"
ct_param_set dir_flatten_unbounded 0
# The walk visits a shared block once (tree_shared_child.sh), which
# collapses this tree to its 254 real extents before any cap: switched
# off, so the cap is the only thing between the tree and the copy.
ct_param_set tree_walk_no_dedup 1

errno_of() {
    python3 -I -c '
import os, sys
try:
    (os.listdir if sys.argv[1] == "ls" else os.stat)(sys.argv[2]); print(0)
except OSError as e:
    print(e.errno)' "$@"
}

# probe <k> <unbounded 0|1> -> "<lookup errno> <ls errno> <secs> <cap named> <count named> <other ok>"
probe() {
    local img dev ino p mark rc1 rc2 t0 t1 other
    img="$(ct_image 2048 "dtfb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d" "$MNT/e"
    : >"$MNT/d/a"
    : >"$MNT/e/a"
    dd if=/dev/urandom of="$MNT/blocks" bs=4096 count=3 conv=fsync status=none
    p="$(filefrag -v -b4096 "$MNT/blocks" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }')"
    ino="$(stat -c %i "$MNT/d")"
    ct_umount "$MNT"
    [ -n "$p" ] && [ "$p" -gt 0 ] || { echo "setup-noblocks"; return; }
    "$TSP" "$img" "$ino" "$p" $((p + 1)) $((p + 2)) "$1" "$p" >&2 || { echo "setup-poke"; return; }
    echo "$2" >/sys/module/cetrafs/parameters/dir_flatten_unbounded
    ct_mount "$dev" "$MNT"
    mark="$(dmesg_mark)"
    t0=$(date +%s)
    rc1="$(errno_of stat "$MNT/d/nonexistent-name")"
    rc2="$(errno_of ls "$MNT/d")"
    t1=$(date +%s)
    other="$(errno_of ls "$MNT/e")"
    echo 0 >/sys/module/cetrafs/parameters/dir_flatten_unbounded
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    local D
    D="$(dmesg_since "$mark")"
    echo "$rc1 $rc2 $((t1 - t0)) $(grep -q "its extent tree holds more than 262144 extents" <<<"$D" && echo yes || echo no)" \
        "$(grep -q "its extents name [0-9]* blocks, more than a directory may hold" <<<"$D" && echo yes || echo no)" \
        "$other"
}

read -r E1 E2 SECS CAP COUNT OTHER <<<"$(probe 254 0)"
case "$E1" in setup-*) fail "setup: $E1"; ct_exit ;; esac
pass "setup: a three-block tree describing 16,387,064 extents is planted"
log "k=254: lookup errno $E1, ls errno $E2, ${SECS}s, flatten cap named: $CAP"
[ "$E1" = 117 ] && [ "$E2" = 117 ] && [ "$CAP" = yes ] &&
    pass "1: lookup and ls are refused (EUCLEAN) by the flatten's cap" ||
    fail "1: lookup errno $E1, ls errno $E2, cap named: $CAP"
[ "$SECS" -le 5 ] && pass "1: in ${SECS}s" || fail "1: the refusal took ${SECS}s -- the tree was walked past the cap"
[ "$OTHER" = 0 ] && pass "2: another directory still lists" || fail "2: listing another directory failed: errno $OTHER"

read -r E1 E2 SECS CAP COUNT OTHER <<<"$(probe 5 1)"
case "$E1" in setup-*) fail "control setup: $E1"; ct_exit ;; esac
[ "$CAP" = no ] && [ "$COUNT" = yes ] &&
    pass "control: with the cap lifted the whole tree is copied and refused only by the count after it" ||
    fail "control: cap named: $CAP, count named: $COUNT -- the suite cannot tell"
ct_param_set tree_walk_no_dedup 0
ct_exit
