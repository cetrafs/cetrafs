#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every CAS swap moves its sector's G-6 stamp past the last, and every CAS writer is a known kind
#
# Audit 2026-11-15 G-6: a CAS-managed sector carries a stamp every swap
# moves to a value no swap wrote before -- low half the swaps it has
# taken, high half the swap's own token -- so a region never returns to
# an earlier image (a late command can never match it again) and a swap
# whose outcome the device never reported is judged by its stamp.
# Staged on one node, on a loop device (the no-CAW path, which stamps
# the same way):
#   setup: the heartbeat swapped this node's registry row at least twice,
#          and the workload ran CAS swaps;
#   1. the row's stamp counted every swap between two reads, and its
#      token changed;
#   2. no swap of the workload was on an address the stamp classifier
#      does not know (cas_unstamped stays 0);
#   3. the stamp survives a remount and goes on counting from the device;
#   4. fsck finds the stamped volume clean;
#   5. the stamp's token names its writer: this node's registry row in
#      its top byte, so no two nodes can write the same one (audit F-75).
#      Not seen here: the registration's own swaps, which use a reserved
#      writer range (a node on row 0 could not tell that from row 0).
#
# NOT STAGED HERE: the verdicts a stamp gives a timed-out command (a
# swap of ours on the device, the image compared, a peer's first swap)
# run only on a device with COMPARE AND WRITE: tests/device/.
#
# DISCRIMINATION: cas_stamp_off=1 -- the row's stamp stands still across
# beats (1 fails); cas_stamp_forget_records=1 -- inode-record swaps are
# counted unstamped (2 fails); cas_token_random=1 -- the token names no
# writer (5 fails, but for a 1-in-256 coincidence).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in cas_stamp_off cas_stamp_forget_records cas_token_random; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt castamp)"
ct_track mnt "$MNT"
ct_param_set cas_stamp_off 0
ct_param_set cas_stamp_forget_records 0
ct_param_set cas_token_random 0
compress_timing

field() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

# <img> <row> -> "hb= stamp="
row_now() {
    local d
    d="$("$NODE_POKE" "$1" "$2")"
    echo "hb=$(field hb_seq "$d") stamp=$(field cas_stamp "$d")"
}

# Wait for the row's hb_seq to move past <hb>, at most 15 s.
beat_past() {
    local img="$1" row="$2" hb="$3" i v
    for i in $(seq 1 60); do
        v="$(row_now "$img" "$row")"
        [ "$(field hb "$v")" -gt "$hb" ] && { echo "$v"; return 0; }
        sleep 0.25
    done
    row_now "$img" "$row"
}

# <stamp_off 0|1> [token_random 0|1] -> "beats= swaps= tokchg= writer= row="
round_row() {
    local img dev proc row a b
    img="$(ct_image 560 "castamp$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    row="$(sed -n 's/^this_node_id: //p' "$proc/info")"
    echo "$1" >/sys/module/cetrafs/parameters/cas_stamp_off
    echo "${2:-0}" >/sys/module/cetrafs/parameters/cas_token_random
    a="$(beat_past "$img" "$row" 0)"
    b="$(beat_past "$img" "$row" "$(field hb "$a")")"
    b="$(beat_past "$img" "$row" "$(field hb "$b")")"
    echo 0 >/sys/module/cetrafs/parameters/cas_stamp_off
    echo 0 >/sys/module/cetrafs/parameters/cas_token_random
    ct_umount "$MNT"
    python3 -I - "$(field hb "$a")" "$(field stamp "$a")" "$(field hb "$b")" "$(field stamp "$b")" "$row" <<'PY'
import sys
ha, sa, hb, sb, row = (int(x) for x in sys.argv[1:6])
print("beats=%d swaps=%d tokchg=%d writer=%d writer0=%d row=%d" % (
    hb - ha, ((sb & 0xffffffff) - (sa & 0xffffffff)) & 0xffffffff, 1 if (sa >> 32) != (sb >> 32) else 0, sb >> 56,
    sa >> 56, row), flush=True)
PY
}

R="$(round_row 0)"
log "stamped: $R"
C="$(round_row 1)"
log "control (stamps off): $C"
for v in "$R" "$C"; do
    [ "$(field beats "$v")" -ge 2 ] || { fail "setup: the heartbeat did not swap the row twice ($v)"; ct_exit; }
done
pass "setup: the heartbeat swapped this node's registry row at least twice"
[ "$(field swaps "$R")" -ge "$(field beats "$R")" ] && [ "$(field tokchg "$R")" = 1 ] &&
    pass "1: the row's stamp counted every beat ($R) and its token changed" ||
    fail "1: the row's stamp did not move with the swaps ($R)"
[ "$(field swaps "$C")" = 0 ] && pass "control: with stamps off, the row's stamp stood still ($C)" ||
    fail "control: the stamp moved anyway -- the assertion cannot fail ($C)"
[ "$(field writer "$R")" = "$(field row "$R")" ] && [ "$(field writer0 "$R")" = "$(field row "$R")" ] &&
    pass "5: the stamp's token names this node's row as its writer ($R)" ||
    fail "5: the token does not name its writer ($R)"
T="$(round_row 0 1)"
log "control (random token): $T"
# Two samples, either differing: a random byte matches the row 1 in 256.
{ [ "$(field writer "$T")" != "$(field row "$T")" ] || [ "$(field writer0 "$T")" != "$(field row "$T")" ]; } &&
    pass "control: a random token names no writer ($T)" ||
    fail "control: the random token named the row anyway -- the assertion cannot fail ($T)"

# <forget 0|1> -> "ops= unstamped= remount= fsck="
round_work() {
    local img dev proc ops0 un0 ops un row s1 s2 remount=0 fsck=0 i
    img="$(ct_image 560 "castampw$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    row="$(sed -n 's/^this_node_id: //p' "$proc/info")"
    ops0="$(sed -n 's/^cas_ops: //p' "$proc/info")"
    un0="$(sed -n 's/^cas_unstamped: //p' "$proc/info")"
    echo "$1" >/sys/module/cetrafs/parameters/cas_stamp_forget_records
    mkdir "$MNT/d"
    for i in $(seq 1 20); do
        dd if=/dev/urandom of="$MNT/d/f$i" bs=64k count=2 conv=fsync status=none
        setfattr -n user.k -v v "$MNT/d/f$i" 2>/dev/null || true
    done
    mv "$MNT/d/f1" "$MNT/d/g1"
    ln "$MNT/d/f2" "$MNT/d/h2"
    rm -f "$MNT/d/f3" "$MNT/d/f4"
    truncate -s 4096 "$MNT/d/f5"
    sync
    echo 0 >/sys/module/cetrafs/parameters/cas_stamp_forget_records
    ops="$(sed -n 's/^cas_ops: //p' "$proc/info")"
    un="$(sed -n 's/^cas_unstamped: //p' "$proc/info")"
    ct_umount "$MNT"
    s1="$(field stamp "$(row_now "$img" "$row")")"
    ct_mount "$dev" "$MNT"
    s2="$(field stamp "$(beat_past "$img" "$row" "$(field hb "$(row_now "$img" "$row")")")")"
    ct_umount "$MNT"
    [ $(((s2 & 0xffffffff) - (s1 & 0xffffffff))) -gt 0 ] && remount=1
    ct_fsck "$dev" >/dev/null 2>&1 && fsck=1
    echo "ops=$((ops - ops0)) unstamped=$((un - un0)) remount=$remount fsck=$fsck"
}

R="$(round_work 0)"
log "workload: $R"
C="$(round_work 1)"
log "control (records unknown): $C"
for v in "$R" "$C"; do
    [ "$(field ops "$v")" -gt 50 ] || { fail "setup: the workload ran too few CAS swaps ($v)"; ct_exit; }
done
pass "setup: the workload ran CAS swaps"
[ "$(field unstamped "$R")" = 0 ] && pass "2: every swap was on a sector the classifier knows ($R)" ||
    fail "2: swaps on unknown sectors ($R)"
[ "$(field unstamped "$C")" -gt 0 ] && pass "control: with records unknown, their swaps were counted unstamped" ||
    fail "control: nothing counted unstamped -- the assertion cannot fail ($C)"
[ "$(field remount "$R")" = 1 ] && pass "3: after a remount the row's stamp went on counting from the device" ||
    fail "3: the stamp did not move after the remount ($R)"
[ "$(field fsck "$R")" = 1 ] && pass "4: fsck finds the stamped volume clean" || fail "4: fsck failed ($R)"
ct_exit
