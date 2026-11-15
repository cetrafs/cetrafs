#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a staged nlink change is the operation's own delta, never lost to a failed second read
#
# A namespace operation stages its record for the lock's release, which
# applies (staged nlink - base) to the device's value. The base came from
# a second, fresh read in cetrafs_inode_stage_record(); when that read
# failed the base became the staged value itself -- a delta of zero. An
# unlink then dropped the name and kept the count: a file live with one
# name fewer than it counts (audit 2026-11-15 BM N-70). The base is now
# the nlink of the record the operation read and changed.
#
# Played on one node, every base read failed (ns_stage_base_read_fail):
#   1. a file with two names loses one: after a remount the survivor
#      counts nlink 1 and fsck is clean;
#   2. a directory renamed across two parents, and one renamed within a
#      parent: every parent counts its subdirectories; fsck clean.
#
# DISCRIMINATION: ns_stage_base_reread=1 (the second read, as before):
# the unlink's decrement is lost -- nlink stays 2 -- and so are the
# rename's parent counts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in ns_stage_base_reread ns_stage_base_read_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt nsb)"
ct_track mnt "$MNT"
ct_param_set ns_stage_base_reread 0
ct_param_set ns_stage_base_read_fail 0
ct_param_set scrub 0
ct_param_set auto_defrag 0

get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <reread 0|1> -> RES
round() {
    local img dev left
    img="$(ct_image 560 "nsb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    echo data >"$MNT/f"
    ln "$MNT/f" "$MNT/g"
    mkdir -p "$MNT/p1/sub" "$MNT/p2" "$MNT/p3/a"
    sync
    echo "$2" >$P/ns_stage_base_reread
    echo 2 >$P/ns_stage_base_read_fail # the parent's stage, then the file's
    rm "$MNT/f"
    left="$(cat $P/ns_stage_base_read_fail)"
    echo 3 >$P/ns_stage_base_read_fail
    mv "$MNT/p1/sub" "$MNT/p2/sub"
    mv "$MNT/p3/a" "$MNT/p3/b"
    echo 0 >$P/ns_stage_base_read_fail
    echo 0 >$P/ns_stage_base_reread
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="left=$left g=$(stat -c %h "$MNT/g") p1=$(stat -c %h "$MNT/p1") p2=$(stat -c %h "$MNT/p2")"
    RES="$RES p3=$(stat -c %h "$MNT/p3") b=$( [ -d "$MNT/p3/b" ] && echo y || echo n)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round c 1
C="$RES"
log "control (base from a second read): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get left "$C")" = 0 ] || { fail "setup: the control's base read was never failed ($C)"; ct_exit; }
[ "$(get g "$R")" = 1 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "1: the unlink's decrement stood: the survivor counts nlink 1; fsck clean" || fail "1: $R"
[ "$(get p1 "$R")" = 2 ] && [ "$(get p2 "$R")" = 3 ] && [ "$(get p3 "$R")" = 3 ] && [ "$(get b "$R")" = y ] &&
    pass "2: renames across and within parents left every parent's count right" || fail "2: $R"
[ "$(get g "$C")" = 2 ] && { [ "$(get p1 "$C")" != 2 ] || [ "$(get p2 "$C")" != 3 ]; } &&
    pass "control: with the base from a failed second read, the decrements were lost ($C)" ||
    fail "control: the failed read did not lose the decrement ($C) -- the suite does not reach the base"
ct_exit
