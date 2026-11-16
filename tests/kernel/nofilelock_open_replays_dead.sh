#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# under nofilelock, opening a file a dead node had open replays that node's journal first
#
# Under the default lock a dead writer's exclusive claim sends the next
# open through the stale-holder branch, which fences the dead node and
# replays its journal before the file is used. Under nofilelock the dead
# node holds no claim -- only its presence bit -- so HA restarting the VM
# elsewhere opened the image past the dead node's unreplayed journal: the
# VM ran without the dead node's last committed tree writes, and the
# heartbeat's replay a stale window later raced the new writer on the same
# leaf (audit 2026-11-14 M-20). The open now replays first.
#
# Node 1 is a dead peer (nofilelock cluster) with the file "img" open --
# its presence bit set -- and one journal entry putting the root's dirent
# block from image s0 to s1. The heartbeat's own replay is held off
# (hb_replay_sweep_off), so only the open can do it:
#   1. after `cat img`, the root's dirent block is s1 and the dead node's
#      area is CLEAN;
#   2. the kernel says it replayed before the open.
#
# DISCRIMINATION: open_replay_stale_off=1 (as before): the block is still
# s0 after the open.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in open_replay_stale_off hb_replay_sweep_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt nord)"
ct_track mnt "$MNT"
ct_param_set open_replay_stale_off 0
ct_param_set hb_replay_sweep_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
first_target() {
    dmesg_mark >/dev/null
    dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1 || true
}
blk() { dd if="$1" of="$3" bs=4096 skip="$2" count=1 iflag=direct status=none; }
put() { dd if="$3" of="$1" bs=4096 seek="$2" count=1 oflag=direct conv=notrunc status=none; }
state() { "$JPOKE" "$1" 1 --dump | head -1 | sed -n 's/^state=\([0-9]*\).*/\1/p'; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }

# <tag> <replay_off 0|1> -> RES
round() {
    local img dev dir mark t ino now st
    img="$(ct_image 560 "nord$1")"
    dev="$(ct_loop "$img")"
    dir="$(ct_tmp "nord-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nfmount "$dev" "$MNT"
    echo data >"$MNT/img"
    ino="$(stat -c %i "$MNT/img")"
    mark="$(dmesg_mark)"
    touch "$MNT/alpha"
    t="$(first_target "$mark")"
    umount "$MNT"
    [ -n "$t" ] || { fail "setup: no journal target logged for a create"; ct_exit; }
    blk "$dev" "$t" "$dir/s0"
    nfmount "$dev" "$MNT"
    touch "$MNT/beta"
    umount "$MNT"
    blk "$dev" "$t" "$dir/s1"
    ! cmp -s "$dir/s0" "$dir/s1" || { fail "setup: the create did not change the root's dirent block"; ct_exit; }
    # node 1 died with img open and its redo of the root block not landed
    put "$dev" "$t" "$dir/s0"
    poke_dead_peer "$dev" 1 aa
    "$(ct_helper node_poke)" "$dev" 1 --mode 2 >/dev/null # it ran nofilelock too
    JOURNAL_POKE_TXN=1 "$JPOKE" "$dev" 1 0 "$t" "$dir/s1" --guard-current >/dev/null
    "$LPOKE" "$dev" "$ino" --reader 1 >/dev/null
    [ "$(state "$dev")" = 1 ] || { fail "setup: the planted entry did not dirty node 1's area"; ct_exit; }

    echo 1 >$P/hb_replay_sweep_off
    echo "$2" >$P/open_replay_stale_off
    nfmount "$dev" "$MNT"
    wait_out_stale_window
    mark="$(dmesg_mark)"
    cat "$MNT/img" >/dev/null 2>&1 || true
    if cmp -s <(dd if="$dev" bs=4096 skip="$t" count=1 iflag=direct status=none) "$dir/s1"; then now=s1
    elif cmp -s <(dd if="$dev" bs=4096 skip="$t" count=1 iflag=direct status=none) "$dir/s0"; then now=s0
    else now=other; fi
    st="$(state "$dev")"
    RES="root=$now area=$st said=$(dmesg_since "$mark" | grep -c 'replayed dead node 1' || true)"
    echo 0 >$P/open_replay_stale_off
    echo 0 >$P/hb_replay_sweep_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round c 1
C="$RES"
log "control (no replay at open): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get root "$R")" = s1 ] && [ "$(get area "$R")" = 0 ] &&
    pass "1: the open replayed the dead node's entry -- root at s1, its area CLEAN" || fail "1: $R"
[ "$(get said "$R")" -ge 1 ] && pass "2: the kernel said it replayed before the open" || fail "2: $R"
[ "$(get root "$C")" = s0 ] && pass "control: without it, the file was opened past the unreplayed entry" ||
    fail "control: the entry was replayed without the open doing it -- something else replays: $C"
ct_exit
