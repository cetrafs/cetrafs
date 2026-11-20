#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group's pool shard never returns to an earlier image: its debits and credits move the G-6 stamp
#
# Audit 2026-11-15 BL-75: the pool shard of unowned Block Groups' free
# capacity lives on the Zone Group record and is moved by delta swaps --
# a release credits it, a claim debits it. Without a writer in the image,
# a credit and the debit that undoes it put the record back to an image
# it held before, so a late command compared against that image could
# land again, and a timed-out swap judged by its image cannot tell its
# own from a peer's equal one. G-6 makes the Zone Group record a stamped
# region: every swap on it moves the stamp to a value no swap wrote
# before, its top byte naming the writer's registry row.
#
# Staged on one node, one Zone Group, two Block Groups: the second is
# emptied, the heartbeat hands it back (credit), and a writer claims it
# back (debit), so the shard ends where it started.
#   setup: the release and the claim both ran, and the shard rose by the
#          group and came back to its starting value;
#   1. the record's stamp moved across the credit and again across the
#      debit, and its top byte names this node's row;
#   2. fsck finds the volume clean.
#
# NOT STAGED HERE: the verdict a stamp gives a timed-out swap -- that runs
# only on a device with COMPARE AND WRITE: tests/device/. This proves the
# pool-shard swaps carry the stamp that verdict reads.
#
# DISCRIMINATION: cas_stamp_off=1 over the credit and the debit -- the
# shard comes back to its value and the stamp stands still, so the record
# returns to its earlier image (1 fails).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cas_stamp_off bg_release_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MAP="$(ct_helper bg_map)"
ZG_POKE="$(ct_helper zg_poke)"
IMG="$(ct_image 1200 zgstamp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgstamp)"
ct_track mnt "$MNT"
compress_timing
for k in cas_stamp_off bg_release_off; do
    ct_param_set "$k" "$(cat /sys/module/cetrafs/parameters/$k)"
done
ct_param_set cas_stamp_off 0
RES="$(ct_tmp zgstamp-res)"

field() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }
zg0() { sync; "$ZG_POKE" "$IMG" 0 stamp; }
bg1_used() { "$MAP" "$DEV" | awk '/^bg 1 /{split($5,a,"[=/]"); exit !(a[2] < a[3])}'; }

# round <stamp_off 0|1>: writes "p0 p1 p2 s0 s1 s2 row fsck" to $RES
round() {
    local off="$1" i=0 mark a b c row fsck=0
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$DEV" | sed -n 's/^counts [0-9]* //p')" = 2 ] ||
        { fail "setup: the volume does not have exactly two Block Groups"; ct_exit; }
    ct_param_set bg_release_off 1
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    row="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    while :; do
        dd if=/dev/zero of="$MNT/f$i" bs=1M count=16 conv=fsync status=none 2>/dev/null || break
        sync
        bg1_used && break
        i=$((i + 1))
        [ "$i" -gt 60 ] && break
    done
    bg1_used || { fail "setup: the fill never reached the second Block Group"; ct_exit; }
    rm -f "$MNT/f$i"
    sync
    a="$(zg0)"
    ct_param_set cas_stamp_off "$off"
    mark="$(dmesg_mark)"
    ct_param_set bg_release_off 0
    wait_for 30 'dmesg_since "'"$mark"'" | grep -q "BG 1 handed back"' ||
        { fail "setup: the heartbeat never handed Block Group 1 back"; ct_exit; }
    ct_param_set bg_release_off 1
    b="$(zg0)"
    dd if=/dev/zero of="$MNT/w" bs=1M count=64 conv=fsync status=none 2>/dev/null || true
    dmesg_since "$mark" | grep -q "claimed free BG 1" ||
        { fail "setup: the writer never claimed Block Group 1 back"; ct_exit; }
    c="$(zg0)"
    ct_param_set cas_stamp_off 0
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && fsck=1
    echo "$(field pool_free_blocks "$a") $(field pool_free_blocks "$b") $(field pool_free_blocks "$c")" \
        "$(field cas_stamp "$a") $(field cas_stamp "$b") $(field cas_stamp "$c") $row $fsck" >"$RES"
}

# <p0 p1 p2>: the shard rose and came back
setup_ok() { [ "$2" -gt "$1" ] && [ "$3" = "$1" ]; }

round 0
read -r P0 P1 P2 S0 S1 S2 ROW FSCK <"$RES"
log "stamped: pool $P0 -> $P1 -> $P2, stamp $S0 -> $S1 -> $S2, row $ROW"
setup_ok "$P0" "$P1" "$P2" || { fail "setup: the shard did not rise and come back ($P0 $P1 $P2)"; ct_exit; }
pass "setup: the release credited the shard and the claim debited it back to $P0"
[ "$S1" != "$S0" ] && [ "$S2" != "$S1" ] && [ "$S2" != "$S0" ] && [ $((S2 >> 56)) = "$ROW" ] &&
    pass "1: the stamp moved across the credit and the debit, and names row $ROW" ||
    fail "1: the shard came back to an earlier image (stamp $S0 -> $S1 -> $S2, row $ROW)"
[ "$FSCK" = 1 ] && pass "2: fsck finds the volume clean" || fail "2: fsck failed"

round 1
read -r P0 P1 P2 S0 S1 S2 ROW FSCK <"$RES"
log "control (stamps off): pool $P0 -> $P1 -> $P2, stamp $S0 -> $S1 -> $S2"
setup_ok "$P0" "$P1" "$P2" || { fail "setup: control: the shard did not rise and come back ($P0 $P1 $P2)"; ct_exit; }
[ "$S0" = "$S1" ] && [ "$S1" = "$S2" ] &&
    pass "control: with stamps off, the shard and its stamp came back to their earlier values" ||
    fail "control: the stamp moved anyway -- the assertion cannot fail ($S0 $S1 $S2)"
ct_exit
