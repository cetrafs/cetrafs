#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create's half-landed record is settled dead by the walks, not counted as damage
#
# A create's whole-record write that stops between its two sectors
# leaves both valid, on different generations. Every whole-table walk
# read it as a bad checksum and counted damage: needs-fsck raised and,
# under corruption=stop, every node whose scrub walked the table stopped
# for one creator's crash (audit 2026-11-15 BM-26; fsck's side is
# BM-69). The walks now read it as an unfinished create and settle it
# like a half-born record: stamped dead, the number reclaimed.
#
#   L1. the new namespace sector landed, naming no creator: settled once
#       it has stayed so for the wait (half_landed_wait_secs here, the
#       stale window in production); nothing counted; fsck clean;
#   W.  the same with a wait longer than the run: left alone, read as
#       unknown -- not settled, not counted;
#   L2. the new file sector landed under a birth claim of an earlier
#       incarnation of this node: settled at once; fsck clean.
#
# DISCRIMINATION: half_landed_damage=1 (as before): L1 is counted as
# damage and the number stays allocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
HB_POKE="$(ct_helper half_born_poke)"
SB_POKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt hls)"
ct_track mnt "$MNT"
ct_param_set half_landed_damage 0
ct_param_set half_landed_wait_secs 4
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
P=/sys/module/cetrafs/parameters
N=500

ibit() {
    python3 -I - "$1" "$2" "$inode_bmap_start" <<'PY'
import sys
img, ino, start = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(img, "rb") as f:
    f.seek(start * 4096 + (ino - 1) // 8)
    print((f.read(1)[0] >> ((ino - 1) % 8)) & 1)
PY
}
info() { sed -n "s/^$1: //p" "$PROC/info"; }
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <ns|fd> <damage 0|1> <wait secs> -> RES
round() {
    local img dev u0 o0 s0 k0 dl me
    img="$(ct_image 560 "hls$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    me="$(info this_node_id)"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=16 conv=fsync status=none
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_(table|bmap)_start=')"
    if [ "$2" = ns ]; then
        "$HB_POKE" "$img" "$N" --landed >/dev/null
    else
        # this node's row; a remount draws a new incarnation, never 7
        "$HB_POKE" "$img" "$N" --landed-fd "$me" 7 >/dev/null
    fi
    echo "$3" >$P/half_landed_damage
    echo "$4" >$P/half_landed_wait_secs
    echo 1 >$P/scrub
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    u0="$(info scrub_unknown_records)" o0="$(info scrub_orphan_inodes_reclaimed)" s0="$(info half_born_settled)"
    k0="$(info corruptions)"
    dl=$((SECONDS + 25))
    while [ "$(info scrub_orphan_inodes_reclaimed)" = "$o0" ] && [ "$SECONDS" -lt "$dl" ]; do
        sleep 1
    done
    RES="unknown=$(($(info scrub_unknown_records) - u0)) settled=$(($(info half_born_settled) - s0))"
    RES="$RES orphans=$(($(info scrub_orphan_inodes_reclaimed) - o0)) corrupt=$(($(info corruptions) - k0))"
    ct_umount "$MNT"
    echo 0 >$P/scrub
    echo 0 >$P/half_landed_damage
    echo 4 >$P/half_landed_wait_secs
    RES="$RES bit=$(ibit "$img" "$N") fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round l1 ns 0 4
A="$RES"
log "L1 (namespace half, no creator named): $A"
round lw ns 0 600
W="$RES"
log "W (namespace half, wait longer than the run): $W"
round l2 fd 0 4
B="$RES"
log "L2 (file half, earlier incarnation's claim): $B"
round lc ns 1 4
C="$RES"
log "control (counted as damage): $C"
[ "$(get settled "$A")" -ge 1 ] || [ "$(get unknown "$A")" -ge 1 ] || [ "$(get corrupt "$A")" -ge 1 ] ||
    { fail "setup: the scrub never reached the record ($A)"; ct_exit; }
[ "$(get settled "$A")" -ge 1 ] && [ "$(get orphans "$A")" -ge 1 ] && [ "$(get corrupt "$A")" = 0 ] &&
    [ "$(get bit "$A")" = 0 ] && [ "$(get fsck_err "$A")" = 0 ] &&
    pass "L1: stamped dead after the wait and reclaimed; nothing counted; fsck clean" || fail "L1: $A"
[ "$(get unknown "$W")" -ge 1 ] && [ "$(get settled "$W")" = 0 ] && [ "$(get corrupt "$W")" = 0 ] &&
    [ "$(get bit "$W")" = 1 ] &&
    pass "W: inside the wait it stays unknown -- neither settled nor counted" || fail "W: $W"
[ "$(get settled "$B")" -ge 1 ] && [ "$(get corrupt "$B")" = 0 ] && [ "$(get bit "$B")" = 0 ] &&
    [ "$(get fsck_err "$B")" = 0 ] &&
    pass "L2: the dead incarnation's create stamped dead and reclaimed; fsck clean" || fail "L2: $B"
[ "$(get corrupt "$C")" -ge 1 ] && [ "$(get bit "$C")" = 1 ] &&
    pass "control: as before, counted as damage and the number stayed allocated" ||
    fail "control: not counted without the change -- the suite does not reach it: $C"
ct_exit
