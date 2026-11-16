#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a late pending-free copy for a group that left the Zone Group is dropped, not damage
#
# A queued free names blocks of a group its Zone Group owned when it was
# queued. A copy that lands late -- after the group was released, or
# claimed again by another Zone Group -- reached the owner check first
# and was counted as corruption: needs-fsck raised and, under
# corruption=stop, the node stopped, for a state the protocol produces
# (audit 2026-11-15 M-7/BM-1).
#
#   R. Block Group 1 released (unowned), a copy in ZG 0's queue: dropped;
#   T. Block Group 1 another Zone Group's, a copy stamped before that
#      tenure: dropped;
#   K. the same, stamped with the current tenure -- no queue of ours
#      could hold that: still counted as corruption.
#
# DISCRIMINATION: pf_late_copy_corrupt=1 (as before): R and T count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PP="$(ct_helper pending_poke)"
BGPOKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt pflc)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set pf_drain_min_ms 600000
P=/sys/module/cetrafs/parameters
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <R|T|K> <knob 0|1> -> RES
round() {
    local img dev d st off gen stamp mark out c0 c1
    img="$(ct_image 1200 "pflc$1")"
    dev="$(ct_loop "$img")"
    if [ "$2" = R ]; then
        ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
        "$BGPOKE" "$img" 1 --owner 65535 >/dev/null
    else
        ct_mkfs "$dev" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    fi
    d="$("$BGPOKE" "$img" 1 --dump)"
    st="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
    off="$(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d")"
    gen="$(sed -n 's/.*free_gen=\([0-9]*\).*/\1/p' <<<"$d")"
    [ -n "$st" ] && [ -n "$gen" ] || { fail "setup: no Block Group 1 ($d)"; ct_exit; }
    stamp=$gen
    [ "$2" = T ] && stamp=$((gen + 7))
    "$PP" "$img" add 0 $((st + off)) 1 "$stamp" >/dev/null || { fail "setup: pending_poke add"; ct_exit; }
    echo "$3" >$P/pf_late_copy_corrupt
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    c0="$(sed -n 's/^corruptions: //p' "$(ct_procdir "$dev")/info")"
    echo 0 >$P/pf_drain_min_ms
    dd if=/dev/urandom of="$MNT/w" bs=4096 count=1 conv=fsync status=none
    sync
    echo 600000 >$P/pf_drain_min_ms
    c1="$(sed -n 's/^corruptions: //p' "$(ct_procdir "$dev")/info")"
    out="$(dmesg_since "$mark")"
    RES="dropped=$(grep -c 'a late copy from before it left -- dropped' <<<"$out" || true)"
    RES="$RES damaged=$(grep -c "came from ZG 0's queue" <<<"$out" || true) corrupt=${c1:-x}"
    ct_umount "$MNT"
    echo 0 >$P/pf_late_copy_corrupt
}

for c in R T K; do
    round "f$c" "$c" 0
    eval "F$c=\"\$RES\""
    log "$c fixed: $RES"
done
for c in R T; do
    round "c$c" "$c" 1
    eval "C$c=\"\$RES\""
    log "$c control: $RES"
done
for c in R T; do
    eval "R=\"\$F$c\" C=\"\$C$c\""
    [ "$(get dropped "$R")" -ge 1 ] && [ "$(get damaged "$R")" = 0 ] && [ "$(get corrupt "$R")" = 0 ] &&
        pass "$c: the late copy was dropped and nothing was counted as damage" || fail "$c: $R"
    [ "$(get damaged "$C")" -ge 1 ] && [ "$(get corrupt "$C")" -ge 1 ] &&
        pass "$c control: as before, the late copy was counted as corruption" ||
        fail "$c control: no corruption without the change -- the drain never reached it: $C"
done
[ "$(get damaged "$FK")" -ge 1 ] && [ "$(get corrupt "$FK")" -ge 1 ] && [ "$(get dropped "$FK")" = 0 ] &&
    pass "K: a copy stamped with the current owner's tenure is still damage" || fail "K: $FK"
ct_exit
