#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory's growth publishes its new block under a new dirent_seq
#
# A walk judges its cached dirent blocks by the directory's dirent_seq
# alone. Growing a directory wrote the record with the new extent and
# the OLD stamp, and the stamp moved only at the entry's release: in
# between, a peer's walk read the new block from its own cache -- for a
# block it held in an earlier life, a valid dirent block of a directory
# since removed (audit 2026-11-15 BM N-72). The growth record now
# carries a new stamp.
#
# A directory grown by a create, paused right after the growth record is
# written (dir_grow_stall_ms), its record read from the device:
#   1. the record lists more blocks than before the create, and its
#      dirent_seq is not the one the previous create left;
#   2. afterwards every name is listed; fsck clean.
#
# DISCRIMINATION: dir_grow_no_stamp=1 (the old record write): the grown
# record carries the previous stamp.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in dir_grow_no_stamp dir_grow_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt dgs)"
ct_track mnt "$MNT"
ct_param_set dir_grow_no_stamp 0
ct_param_set dir_grow_stall_ms 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <no_stamp 0|1> -> RES
round() {
    local img dev ino i pid pre mid="" n
    img="$(ct_image 560 "dgs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    touch "$MNT/d/x0"
    ino="$(stat -c %i "$MNT/d")"
    sync
    echo "$2" >$P/dir_grow_no_stamp
    echo 3000 >$P/dir_grow_stall_ms
    for i in $(seq 1 60); do
        pre="$("$LOCK_POKE" "$img" --rec "$ino")"
        touch "$MNT/d/f$i" &
        pid=$!
        sleep 0.3
        if [ "$(cat $P/dir_grow_stall_ms)" = 0 ]; then
            mid="$("$LOCK_POKE" "$img" --rec "$ino")"
            wait "$pid"
            break
        fi
        wait "$pid"
    done
    echo 0 >$P/dir_grow_stall_ms
    echo 0 >$P/dir_grow_no_stamp
    n="$(ls "$MNT/d" | wc -l)"
    ct_umount "$MNT"
    RES="i=$i pre_blocks=$(get blocks "$pre") pre_seq=$(get dirent_seq "$pre")"
    RES="$RES mid_blocks=$(get blocks "$mid") mid_seq=$(get dirent_seq "$mid") names=$n"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round c 1
C="$RES"
log "control (growth keeps the old stamp): $C"
round f 0
R="$RES"
log "fixed: $R"
for x in "$C" "$R"; do
    [ -n "$(get mid_blocks "$x")" ] && [ "$(get mid_blocks "$x")" -gt "$(get pre_blocks "$x")" ] ||
        { fail "setup: no create was caught growing the directory ($x)"; ct_exit; }
done
[ "$(get mid_seq "$R")" != "$(get pre_seq "$R")" ] &&
    pass "1: the grown record carries a new dirent_seq ($(get pre_seq "$R") -> $(get mid_seq "$R"))" || fail "1: $R"
[ "$(get names "$R")" = "$(($(get i "$R") + 1))" ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: every name is listed; fsck clean" || fail "2: $R"
[ "$(get mid_seq "$C")" = "$(get pre_seq "$C")" ] &&
    pass "control: the old growth write published the new block under the previous stamp" ||
    fail "control: the stamp moved without the fix ($C) -- the suite does not see the growth write"
ct_exit
