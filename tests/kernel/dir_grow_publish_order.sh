#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a growing directory publishes its new extent root before the dirent_seq that announces it
#
# A peer trusts its cached dirent blocks while the directory's dirent_seq
# (record sector 0) is the one it holds, and takes the extent root from
# sector 1. Directory growth wrote both sectors in one 4 KiB write: torn
# by a crash or a path failure, sector 0 can land without sector 1, each
# passing its own CRC and echo -- the new stamp with the old root, which
# a peer then caches as current until the directory next changes (audit
# 2026-11-22, N-46). Growth now publishes the file sector, then swaps the
# stamp in alone, the order cetrafs.h names as the barrier.
#
# What this suite sees: the device between the two publishes
# (dir_grow_publish_stall_ms). It holds the new root under the OLD stamp
# -- the order -- and the stamp moves after. A loop device does not tear
# a 4 KiB write, so the tear itself is not reproduced here: the control
# (dir_grow_whole_write=1) shows only that the old path has no such
# intermediate state, both sectors moving in one write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in dir_grow_whole_write dir_grow_publish_stall_ms; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"
IPOKE="$(ct_helper inode_block_poke)"
ct_param_set dir_grow_whole_write 0
ct_param_set dir_grow_publish_stall_ms 0
ct_param_set auto_defrag 0
MNT="$(ct_mnt dgpo)"
ct_track mnt "$MNT"

# round <tag> <whole> -> RES "root_mid seq_mid seq_after"
round() {
    local img dev d i seq0 ext0 pid mid_seq mid_ext end_seq
    img="$(ct_image 560 "dgpo$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/d"
    d="$(stat -c %i "$MNT/d")"
    # 15 slots a block, '.' and '..' among them: 13 names fill the first
    for i in $(seq 1 13); do : >"$MNT/d/n$i"; done
    sync
    seq0="$("$LPOKE" "$img" "$d" --rec | sed -n 's/.*dirent_seq=\([0-9]*\).*/\1/p')"
    ext0="$("$IPOKE" "$img" extents "$d" | sed -n "s/^depth=.* blocks=\([0-9]*\).*/\1/p")"
    echo "$2" >$P/dir_grow_whole_write
    echo 3000 >$P/dir_grow_publish_stall_ms
    : >"$MNT/d/grow" &
    pid=$!
    sleep 1.5
    mid_seq="$("$LPOKE" "$img" "$d" --rec | sed -n 's/.*dirent_seq=\([0-9]*\).*/\1/p')"
    mid_ext="$("$IPOKE" "$img" extents "$d" | sed -n "s/^depth=.* blocks=\([0-9]*\).*/\1/p")"
    kill -0 "$pid" 2>/dev/null && held=y || held=n
    wait "$pid" || true
    echo 0 >$P/dir_grow_whole_write
    echo 0 >$P/dir_grow_publish_stall_ms
    sync
    end_seq="$("$LPOKE" "$img" "$d" --rec | sed -n 's/.*dirent_seq=\([0-9]*\).*/\1/p')"
    ct_umount "$MNT"
    RES="held=$held ext0=$ext0 ext_mid=$mid_ext seq_mid_moved=$([ "$mid_seq" != "$seq0" ] && echo y || echo n)"
    RES="$RES seq_end_moved=$([ "$end_seq" != "$seq0" ] && echo y || echo n)"
    ct_fsck "$dev" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
    log "$1: $RES"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2; }

round ctl 1
[ "$(get held "$RES")" = y ] && [ "$(get ext_mid "$RES")" -gt "$(get ext0 "$RES")" ] || {
    fail "control setup: the growth was not held after its write, or grew nothing: $RES"
    ct_exit
}
[ "$(get seq_mid_moved "$RES")" = y ] &&
    pass "control: one whole-record write moves the root and the stamp together ($RES)" ||
    fail "control: the old path left the stamp behind -- the suite does not see the two writes: $RES"
round fixed 0
[ "$(get held "$RES")" = y ] && [ "$(get ext_mid "$RES")" -gt "$(get ext0 "$RES")" ] ||
    { fail "setup: the growth was not held between its publishes, or grew nothing: $RES"; ct_exit; }
[ "$(get seq_mid_moved "$RES")" = n ] &&
    pass "between the publishes the device holds the new root under the old stamp ($RES)" ||
    fail "the stamp was on the device before the growth's root was: $RES"
[ "$(get seq_end_moved "$RES")" = y ] && [ "$(get fsck "$RES")" = ok ] &&
    pass "and the stamp moved after it; fsck clean" || fail "the stamp never moved, or fsck: $RES"
ct_exit
