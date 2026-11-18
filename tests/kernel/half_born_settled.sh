#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a half-born record whose creator is gone is stamped dead; the recount reads one as naming nothing
#
# A birth claim over a never-written slot leaves a HALF-BORN record (the
# namespace sector claimed, the file sector still zeros) until the
# create writes its record. If the creator stopped there, every walk
# that frees read it as unknown: no scrub cycle freed anything and the
# namespace recount of every file failed, on every node, until an
# offline fsck -r (audit 2026-11-15 F-12). The record names its creator,
# so a walk now settles it when that creator is gone, and the recount
# reads a half-born record as what it is: not a directory, naming
# nothing.
#
#   S1. a half-born record claimed by an earlier incarnation of this
#       node: the scrub stamps it dead, meets nothing unknown, and
#       reclaims the number; fsck clean;
#   S2. the same, claimed by a peer that is stale: fenced, stamped dead,
#       reclaimed; fsck clean;
#   N.  a half-born record left as it is (its creator taken as live),
#       and a file's namespace lock held by a dead peer: an fchmod takes
#       it over and recounts, and succeeds; the file keeps nlink 1.
#
# DISCRIMINATION: half_born_settle_off=1 (S1): every cycle meets an
# unknown record and the number stays allocated.
# ns_count_half_born_unknown=1 (N): the recount fails and so does the
# fchmod.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in half_born_settle_off ns_count_half_born_unknown; do
    [ -w /sys/module/cetrafs/parameters/$k ] || { skip "$k is missing"; ct_exit; }
done
HB_POKE="$(ct_helper half_born_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
SB_POKE="$(ct_helper sb_poke)"
BMAP_POKE="$(ct_helper bmap_poke)"
MNT="$(ct_mnt hbs)"
ct_track mnt "$MNT"
ct_param_set half_born_settle_off 0
ct_param_set ns_count_half_born_unknown 0
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
P=/sys/module/cetrafs/parameters
N=500

ibit() {
    "$BMAP_POKE" "$1" "$inode_bmap_start" "$(($2 - 1))"
}
info() { sed -n "s/^$1: //p" "$PROC/info"; }

# --- S: the scrub -----------------------------------------------------------
# <tag> <creator: self|peer> <settle_off 0|1> -> RES
scrub_round() {
    local img dev c0 u0 o0 s0 dl me
    img="$(ct_image 560 "hbs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    me="$(info this_node_id)"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=16 conv=fsync status=none
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_(table|bmap)_start=')"
    if [ "$2" = self ]; then
        # this node's row; a remount draws a new incarnation, never 7
        "$HB_POKE" "$img" "$N" "$me" 7 >/dev/null
    else
        "$HB_POKE" "$img" "$N" 1 7 >/dev/null
        poke_dead_peer "$dev" 1 bb
    fi
    echo "$3" >$P/half_born_settle_off
    echo 1 >$P/scrub
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    c0="$(info scrub_cycles)" u0="$(info scrub_unknown_records)" o0="$(info scrub_orphan_inodes_reclaimed)"
    s0="$(info half_born_settled)"
    [ "$2" = peer ] && wait_out_stale_window
    dl=$((SECONDS + 90))
    while [ "$(info scrub_cycles)" -lt $((c0 + 2)) ] && [ "$(info scrub_unknown_records)" -lt $((u0 + 2)) ] &&
        [ "$SECONDS" -lt "$dl" ]; do
        sleep 1
    done
    # the orphan pass runs after the cycle that stamped it
    dl=$((SECONDS + 30))
    while [ "$3" = 0 ] && [ "$(info scrub_orphan_inodes_reclaimed)" = "$o0" ] && [ "$SECONDS" -lt "$dl" ]; do
        sleep 1
    done
    RES="me=$me cycles=$(($(info scrub_cycles) - c0)) unknown=$(($(info scrub_unknown_records) - u0))"
    RES="$RES settled=$(($(info half_born_settled) - s0)) orphans=$(($(info scrub_orphan_inodes_reclaimed) - o0))"
    ct_umount "$MNT"
    echo 0 >$P/scrub
    echo 0 >$P/half_born_settle_off
    RES="$RES bit=$(ibit "$img" "$N") fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

# --- N: the namespace recount ------------------------------------------------
# <tag> <half_born_unknown 0|1> -> RES
recount_round() {
    local img dev t fi nl setup wpid
    img="$(ct_image 560 "hbn$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    echo payload >"$MNT/d/F"
    fi="$(stat -c %i "$MNT/d/F")"
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_(table|bmap)_start=')"
    # creator: a node that is never judged gone here (settling off)
    "$HB_POKE" "$img" "$N" 2 7 >/dev/null
    echo 1 >$P/half_born_settle_off
    echo "$2" >$P/ns_count_half_born_unknown
    ct_mount "$dev" "$MNT"
    t="$(ct_tmp "hbn-ctl$1")"
    rm -rf "$t"
    mkdir -p "$t"
    python3 -I - "$MNT/d/F" "$t" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
open(os.path.join(sys.argv[2], "w"), "w").close()
while not os.path.exists(os.path.join(sys.argv[2], "go")):
    time.sleep(0.05)
try:
    os.fchmod(fd, 0o600)
    r = "ok"
except OSError as e:
    r = "errno%d" % e.errno
open(os.path.join(sys.argv[2], "r"), "w").write(r)
os.close(fd)
PY
    wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    "$LOCK_POKE" "$img" "$fi" --ns 1 >/dev/null
    poke_dead_peer "$dev" 1 bb
    setup="$("$LOCK_POKE" "$img" --rec "$fi") $("$LOCK_POKE" "$img" "$fi")"
    wait_out_stale_window
    touch "$t/go"
    wait "$wpid" || true
    nl="$("$LOCK_POKE" "$img" --rec "$fi" | sed -n 's/.*nlink=\([0-9]*\).*/\1/p')"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/half_born_settle_off
    echo 0 >$P/ns_count_half_born_unknown
    RES="fchmod=$(cat "$t/r" 2>/dev/null || echo none) nlink=$nl hb=$(ibit "$img" "$N") setup=[$setup]"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

scrub_round s1 self 0
A="$RES"
log "S1 (this node's earlier incarnation): $A"
scrub_round s2 peer 0
B="$RES"
log "S2 (a stale peer): $B"
scrub_round sc self 1
C="$RES"
log "S control (settling off): $C"
[ "$(get cycles "$A")" -ge 2 ] && [ "$(get unknown "$A")" = 0 ] && [ "$(get settled "$A")" -ge 1 ] &&
    [ "$(get orphans "$A")" -ge 1 ] && [ "$(get bit "$A")" = 0 ] && [ "$(get fsck_err "$A")" = 0 ] &&
    pass "S1: stamped dead and the number reclaimed; nothing unknown; fsck clean" || fail "S1: $A"
[ "$(get unknown "$B")" = 0 ] && [ "$(get settled "$B")" -ge 1 ] && [ "$(get bit "$B")" = 0 ] &&
    [ "$(get fsck_err "$B")" = 0 ] &&
    pass "S2: the stale peer's create stamped dead and reclaimed; fsck clean" || fail "S2: $B"
[ "$(get unknown "$C")" -ge 2 ] && [ "$(get bit "$C")" = 1 ] &&
    pass "S control: left half-born, every cycle met an unknown record and the number stayed allocated" ||
    fail "S control: settling off and the scrub still got past it ($C) -- the suite cannot see the settle"

recount_round n 0
R="$RES"
log "N fixed: $R"
recount_round nc 1
NC="$RES"
log "N control (half-born unknown): $NC"
grep -q 'ns_owner=1 ' <<<"${R#*setup=} " && [ "$(get hb "$R")" = 1 ] ||
    { fail "N setup: the dead peer's lock or the half-born record was not in place ($R)"; ct_exit; }
[ "$(get fchmod "$R")" = ok ] && [ "$(get nlink "$R")" = 1 ] &&
    pass "N: the recount read the half-born record as naming nothing; fchmod ok, nlink 1" || fail "N: $R"
[ "$(get fchmod "$NC")" != ok ] &&
    pass "N control: a half-born record unknown to the recount fails the fchmod ($(get fchmod "$NC"))" ||
    fail "N control: the recount got past an unknown half-born record ($NC) -- the suite does not reach it"
ct_exit
